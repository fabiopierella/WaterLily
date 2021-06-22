using WaterLily
using BenchmarkTools
using LinearAlgebra: norm2
using Profile

radius = 8; Re = 250
body = AutoBody((x,t)-> √sum(abs2,x .- 2radius) - radius)
body_sim(T=Float64) = Simulation((6radius+2,4radius+2),[1.,0.],radius; body, ν=radius/Re,T)

L = 2^5
function uλ(i,vx)
    x,y,z = @. (vx-1.5)*π/L              # scaled coordinates
    i==1 && return -sin(x)*cos(y)*cos(z) # u_x
    i==2 && return  cos(x)*sin(y)*cos(z) # u_y
    return 0.                            # u_z
end
vort_sim(T=Float64) = Simulation((L+2,L+2,L+2),zeros(3),L;uλ,ν=L/Re,U=1.,T)

benchmark_step() = @benchmark mom_step!($sim.flow,$sim.pois)
benchmark_vort() = @benchmark sim_step!(sim,10) setup=(sim=vort_sim()) seconds=30
benchmark_body() = @benchmark sim_step!(sim,10) setup=(sim=body_sim())
