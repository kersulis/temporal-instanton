module TemporalInstanton

using HDF5, JLD, ProgressMeter, IProfile

export
    solve_instanton_qcqp, solve_temporal_instanton, LineParams,
    ConductorParams,
    # temporary:
    tmp_inst_Qobj,tmp_inst_A1,tmp_inst_b,tmp_inst_Qtheta,
    return_conductor_params,return_thermal_constants,tmp_inst_A2,

    # power flow:
    expand_renewable_vector,fixed_wind_A,fixed_wind_b,return_angles,
    return_angle_diffs

include("PowerFlow.jl")
include("ThermalModel.jl")
include("QCQPMatrixBuilding.jl")
include("manipulations.jl")
include("SolveSecular.jl")

""" Solve the following quadratically-
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

The solution method is due in part to Dr. Dan
Bienstock of Columbia University. It involves
translating and rotating the problem, using
partial KKT conditions, and solving the
resulting secular equation.
"""
function solve_instanton_qcqp(G_of_x,Q_of_x,A,b,T)
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

    N = kernel_rotation(A, spqr=false) # take only cols spanning N(A)

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

""" Perform temporal instanton analysis on
many lines in a system at once. Inputs:

* `Ridx`            Vector: indices of nodes that have wind farms
* `Y`               Admittance matrix
* `G0`              Conventional generation dispatch
* `P0`              Renewable generation forecast
* `D0`              Conventional demand
* `Sb`              System base voltage
* `ref`             Index of system angle reference bus
* `lines`           Vector: tuples (from,to) of lines to loop through
* `res`             Vector: pu resistance for all lines
* `reac`            Vector: pu reactance for all lines
* `k`               Vector: conventional generator participation factors
* `line_lengths`    Vector: line lengths in meters
* `line_conductors` Vector: strings (e.g. "waxwing") indicating conductor types
* `Tamb`            Ambient temperature
* `T0`              Initial line temperature (TODO: compute within)
* `int_length`      Length of each time interval in seconds
"""
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
    line_conductors,
    Tamb,
    T0,
    int_length)

    # Initialize progress meter:
    prog = Progress(length(find(line_lengths)),1)

    n = length(k)
    nr = length(Ridx)
    T = round(Int64,length(find(P0))/nr)
    numLines = length(lines)

    # Vars used to store results:
    score = Float64[]
    α = Array(Vector{Float64},0)
    θ = Array(Array,0)
    x = Array(Array,0)
    diffs = Array(Array,0)
    xopt = Array(Array,0)

    # Form objective quadratic:
    Qobj = tmp_inst_Qobj(n,nr,T; pad=true)
    G_of_x = (Qobj,0,0)

    # Create A1 (only A2, the bottom part,
    # changes during line loop):
    A1 = tmp_inst_A1(Ridx,T,Y,ref,k; pad=true)

    b = tmp_inst_b(n,T,G0,P0,D0; pad=true)
    Qtheta = tmp_inst_Qtheta(n,nr,T)

    # parallelize the loop:
    # addprocs(3)

    # Loop through all lines excluding those with zero length:
    nz_line_idx = find(line_lengths.!=0)

    # initialize conductor_name
    # conductor_name = "init"
    # conductor_params = ConductorParams(15.5e-3,383.,439.,110e-6,65.,0.955,2.207e-9,14.4)

    # loop through lines (having non-zero length)
    for idx in nz_line_idx
        line = lines[idx]
        conductor_name = line_conductors[idx]
        conductor_params = return_conductor_params(conductor_name)

        # if current line uses a different conductor than previous,
        # re-compute conductor_params:
        # if line_conductors[idx] != conductor_name
        #     conductor_name = line_conductors[idx]
        #     conductor_params = return_conductor_params(conductor_name)
        # end
        # compute line_params based on current line:
        line_params = LineParams(line[1],line[2],res[idx],reac[idx],line_lengths[idx])

        (therm_a,therm_c,therm_d,therm_f) = return_thermal_constants(line_params,conductor_params,Tamb,Sb,int_length,T,T0)

        # thermal constraint, Q(z) = 0:
        kQtheta = (therm_a/therm_c)*(conductor_params.Tlim - therm_f)
        Q_of_x = (Qtheta,0,kQtheta)

        # array of vectors with Float64 values:
        deviations = Array(Vector{Float64},0)
        angles = Array(Vector{Float64},0)
        alpha = Float64[]

        # Create A2 based on chosen line:
        A2 = tmp_inst_A2(n,Ridx,T,line,therm_a,int_length)
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

        # update ProgressMeter
        next!(prog)
    end
    # shut down procs (parallelization over)
    #rmprocs([2,3,4])
    return score,x,θ,α,diffs,xopt
end

end
