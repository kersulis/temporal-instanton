module TemporalInstanton

using HDF5, JLD, ProgressMeter, IProfile

export
    solve_instanton_qcqp, solve_temporal_instanton, LineModel,
    # temporary:
    tmp_inst_Qobj,tmp_inst_pad_Q,tmp_inst_A,tmp_inst_b,tmp_inst_pad_b,
    tmp_inst_Qtheta,add_thermal_parameters,compute_a,compute_c,
    compute_d,compute_f,tmp_inst_A_scale_new

include("PowerFlow.jl")
include("ThermalModel.jl")
include("QCQPMatrixBuilding.jl")

@iprofile begin
function partition_A(A,Qobj,T)
    """ Return A1, A2, A3 where:
    * A1 corresponds to wind
    * A2 corresponds to angles + mismatch
    * A3 corresponds to angle difference vars

    Used to find x_star, the min-norm solution to
    Ax=b such that x_star[idx3] = 0.
    """
    m,n = size(A)
    idx1 = find(diag(Qobj))
    idx2 = setdiff(1:n-T,idx1)
    idx3 = n-T+1:n

    (A1,A2) = (A[:,idx1],A[:,idx2])
    return A1,A2,idx1,idx2,idx3
end

function find_x_star(A1,A2,idx1,idx2,n,b)
    """ x_star is the n-vector by which the problem must
    be translated in the first step of the temporal
    instanton QCQP solution.

    x_star is chosen to be the point in the set Ax=b
    nearest to the origin such that x_star[idx3] = 0.
    This condition ensures no linear term is introduced
    into the quadratic constraint.
    """
    x_star = zeros(n)
    Z = sparse([A1 A2]')
    x_star[[idx1;idx2]] = (Z/(Z'*Z))*b
    return x_star
end

function translate_quadratic(G_of_x,x_star)
    """ This function performs the change of variables from x to z,
    where z = x - x_star. (For translating a quadratic problem.)
    Returns triple H_of_x consisting of matrix H, vector h, constant kh.

    Arguments
    G_of_x consists of matrix G, vector g, constant kg.
    x_star is translation.

    Used to perform second step of temporal instanton solution method,
    assuming x_star is min-norm solution of Ax=b.
    """
    G,g,kg = G_of_x
    if g == 0
        g = zeros(size(G,1),1)
    end
    H = G
    h = g + 2*G*x_star
    kh = kg + x_star'*G*x_star + g'*x_star
    return (H,h,kh[1])
end

function kernel_rotation(A)
    """ Find an orthonormal basis for the nullspace of A.
    This matrix may be used to rotate a temporal instanton
    problem instance to eliminate all but nullity(A) elements.
    """
    m,n = size(A)

    # Assume A always has full row rank.
    #if isposdef(A*A')
    dim_N = n - m
    # else
    #     dim_N = n - rank(A)
    #     warn("A does not have full row rank.")
    # end
    q = qr(A'; thin=false)[1]
    R = circshift(q,(0,dim_N))
    return R
end

function rotate_quadratic(G_of_x,R)
    """ Rotate quadratic G_of_x by
    rotation matrix R.
    """
    G,g,kg = G_of_x
    return (R*G*R',R*g,kg)
end

function return_K(D)
    """ Return K, the diagonal matrix whose elements are
    square roots of eigenvalues of the given matrix D.
    """
    K = ones(length(D))
    K[find(D)] = sqrt(D[find(D)])
    return diagm(K)
end

function partition_B(G_of_w,Q_of_w)
    B,b = G_of_w[1],G_of_w[2]
    Q = round(Q_of_w[1])
    i2 = find(diag(Q))
    i1 = setdiff(1:size(Q,1),i2)
    B11,B12,B21,B22 = B[i1,i1],B[i1,i2],B[i2,i1],B[i2,i2]
    b1 = b[i1]
    b2 = b[i2]
    return B11,B12,B21,B22,b1,b2
end

function return_Bhat(B11,B12,B22,b1,b2)
    Bhat = B22 - (B12'/B11)*B12
    bhat = b2 - (B12'/B11)*b1
    return round(Bhat,10),bhat
end

function find_w(v,D,d)
    if v == 0
        w = float([-d[i]/(D[i,i]) for i in 1:length(d)])
    else
        w = float([d[i]/(v - D[i,i]) for i in 1:length(d)])
    end
    return w
end

function solve_secular(D,d,c)
    """ Solve the secular equation via binary search.
    """
    eps = 1e-8
    solutions = Float64[]
    vectors = Array(Vector{Float64},0)
    poles = sort(unique(round(diag(D),10)))

    # Each diagonal element is a pole.
    for i in 1:length(poles)

        # Head left first:
        high = poles[i]
        if length(poles) == 1
            low = high - high
        elseif i == 1
            low = high - abs(poles[i] - poles[i+1])
        else
            low = high - abs(poles[i] - poles[i-1])/2
        end

        # Initialize v:
        v = (high + low)/2
        w = find_w(v,D,d)
        diff = (w'*w)[1] - c
        diff_old = 0
        stall = false
        while abs(diff) > eps
            if diff == diff_old
                stall = true
                break
            end
            if diff > 0
                high = v
            else
                low = v
            end
            v = (high + low)/2
            w = find_w(v,D,d)
            diff_old = diff
            diff = (w'*w)[1] - c
        end
        if !stall
            push!(solutions,v)
            push!(vectors,w)
        end

        # Now head right:
        high = poles[i]
        if length(poles) == 1
            low = high + high
        elseif i == length(poles)
            low = high + abs(poles[i] - poles[i-1])
        else
            low = high + abs(poles[i] - poles[i+1])/2
        end

        v = (high + low)/2
        w = find_w(v,D,d)
        diff = (w'*w)[1] - c
        diff_old = 0
        stall = false
        while abs(diff) > eps
            if diff == diff_old
                stall = true
                break
            end
            if diff > 0
                high = v
            else
                low = v
            end
            v = (high + low)/2
            w = find_w(v,D,d)
            diff_old = diff
            diff = (w'*w)[1] - c
        end
        if !stall
            push!(solutions,v)
            push!(vectors,w)
        end
    end
    return solutions,vectors
end

function return_xopt(w2opt,B11,B12,b1,N,U,K,x_star)
    """ Reverse rotations and translations to map
    secular equation solution back to original problem
    space.
    """
    w1opt = -B11\(B12*w2opt + b1/2)
    wopt = [w1opt;w2opt]
    #xopt = (N*U/K)*wopt + x_star
    xopt = N*U*diagm(1./diag(K))*wopt + x_star
    return xopt
end

end # @iprofile begin

function solve_instanton_qcqp(G_of_x,Q_of_x,A,b,T)
    """ This function solves the following quadratically-
    constrained quadratic program:

        min  G_of_x
        s.t. A*x = b
             Q_of_x = 0

    where   G_of_x = x'*Qobj*x,
            Q_of_x = x'*Qtheta*x - c

    Thus, an equivalent problem expression is:

        min  z'*Qobj*z
        s.t. A*z = b
             z'*Qtheta*z = c

    The solution method is due in part to work by
    Dr. Dan Bienstock of Columbia University. It
    involves translating and rotating the problem,
    using partial KKT conditions, and solving the
    resulting secular equation.
    """
    m,n = size(A)
    Qobj = G_of_x[1]
    c = - Q_of_x[3]

    opt = Array(Vector{Float64},0)

    # Partition A:
    A1,A2,idx1,idx2,idx3 = partition_A(A,Qobj,T)

    # Find translation point:
    x_star = find_x_star(A1,A2,idx1,idx2,n,b)

    # Translate quadratics:
    G_of_y = translate_quadratic(G_of_x,x_star)
    Q_of_y = translate_quadratic(Q_of_x,x_star)

    N = kernel_rotation(A)[:,1:size(A,2) - rank(A)] # take only first k cols

    N1,N2,N3 = N[idx1,:],N[idx2,:],N[idx3,:] # partition N

    G_of_z = rotate_quadratic(G_of_y,N')
    Q_of_z = rotate_quadratic(Q_of_y,N')

    D,U = eig(Q_of_z[1])
    D = round(D,10)

    K = return_K(D)

    G_of_w = rotate_quadratic(G_of_z,(U/K)')
    Q_of_w = rotate_quadratic(Q_of_z,(U/K)')

    B11,B12,B21,B22,b1,b2 = partition_B(G_of_w,Q_of_w)

    Bhat,bhat = return_Bhat(B11,B12,B22,b1,b2)

    eps = 1e-8
    w0 = find_w(0,Bhat,bhat/2)

    if abs((w0'*w0) - c)[1] < eps
        println("v=0 works!")
    end

    solutions, vectors = solve_secular(Bhat,bhat/2,-Q_of_w[3])
    if isempty(solutions)
        return [],Inf
    else
        sol = zeros(length(vectors))
        for i in 1:length(vectors)
            w2 = vectors[i]
            xvec = return_xopt(w2,B11,B12,b1,N,U,K,x_star)
            sol[i] = (xvec'*Qobj*xvec)[1]
            push!(opt,xvec)
        end
    end

    return opt[indmin(sol)],minimum(sol)
end

function solve_temporal_instanton(
    Ridx,
    Y,
    G0,
    P0,
    D0,
    Sb,
    ref,
    lines,
    res,
    reac,
    k,
    line_lengths,
    Tamb,
    T0,
    int_length)
    """ Convenience function used to perform temporal
    instanton analysis on many lines in a system at once.
    """

    n = length(k)
    nr = length(Ridx)
    T = int64(length(find(P0))/nr)

    numLines = length(lines)

    # Initialize progress meter:
    prog = Progress(length(find(line_lengths)),1)

    # Initialize vars used to store results:
    score = Float64[]
    α = Array(Vector{Float64},0)

    θ = Array(Array,0)
    x = Array(Array,0)
    diffs = Array(Array,0)
    xopt = Array(Array,0)

    # Create Qobj:
    Qobj = tmp_inst_Qobj(n,nr,T)
    # Augment Qobj with additional rows and columns of zeros:
    Qobj = tmp_inst_pad_Q(full(Qobj),T)

    # Create A1 (only A2 changes during opt.):
    A1 = full(tmp_inst_A(Ridx,T,Y,ref,k))
    A1 = [A1 zeros((n+1)*T,T)]

    # Create b:
    b = tmp_inst_b(n,T,G0,P0,D0)
    # Augment b with new elements:
    tmp_inst_pad_b(b,T)

    # Create Qtheta:
    Qtheta = tmp_inst_Qtheta(n,nr,T)

    # Form objective quadratic:
    G_of_x = (Qobj,0,0)

    # addprocs(3)
    # Loop through all lines:
    for idx = 1:numLines
        # thermal model cannot handle zero-length lines:
        if line_lengths[idx] == 0
            continue
        end
        line = lines[idx]
        line_model = LineModel(line[1],
                    line[2],
                    res[idx],
                    reac[idx],
                    line_lengths[idx],
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    NaN)

        add_thermal_parameters(line_model, "waxwing")

        therm_a = compute_a(line_model.mCp,
                            line_model.ηc,
                            line_model.ηr,
                            Tamb,
                            line_model.Tlim)
        therm_c = compute_c(line_model.mCp,
                            line_model.rij,
                            line_model.xij,
                            Sb,
                            line_model.length)
        therm_d = compute_d(line_model.mCp,
                            line_model.ηc,
                            line_model.ηr,
                            Tamb,
                            line_model.Tlim,
                            line_model.qs)
        therm_f = compute_f(int_length,
                            therm_a,
                            therm_d,
                            T,
                            T0)

        # thermal constraint, Q(z) = 0:
        kQtheta = (therm_a/therm_c)*(line_model.Tlim - therm_f)
        Q_of_x = (Qtheta,0,kQtheta)

        # array of vectors with Float64 values:
        deviations = Array(Vector{Float64},0)
        angles = Array(Vector{Float64},0)
        alpha = Float64[]

        # Create A2 based on chosen line:
        A2 = tmp_inst_A_scale_new(n,Ridx,T,line,therm_a,int_length)
        # Stack A1 and A2:
        A = [A1; A2]

        # Computationally expensive part: solving QCQP
        xvec,sol = solve_instanton_qcqp(G_of_x,Q_of_x,A,b,T)

        push!(score,sol)
        if isinf(sol)
            push!(deviations,[])
            push!(angles,[])
            push!(alpha,NaN)
            push!(diffs,[])
        else

            # Variable breakdown:
            # (nr+n+1) per time step
            #   First nr are deviations
            #   Next n are angles
            #   Last is mismatch
            # T variables at the end: anglediffs
            for t = 1:T
                push!(deviations,xvec[(nr+n+1)*(t-1)+1:(nr+n+1)*(t-1)+nr])
                push!(angles,xvec[(nr+n+1)*(t-1)+nr+1:(nr+n+1)*(t-1)+nr+n])
                push!(alpha,xvec[(nr+n+1)*(t)])
            end
            push!(diffs,xvec[end-T+1:end])
        end

        push!(x,deviations)
        push!(θ,angles)
        push!(α,alpha)
        push!(xopt,xvec)

        next!(prog)
    end
    #rmprocs([2,3,4])
    return score,x,θ,α,diffs,xopt
end

end
