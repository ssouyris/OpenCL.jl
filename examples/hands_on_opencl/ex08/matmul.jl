# Matrix Multiplication Driver
#
# This is a driver program to test various ways of computing
# the product:
#                 C = A * B
#
# A and B are constant matrices, square and the order is
# set as a constant, ORDER (see definitions.py). This is so
# we can make a quick test of the multiplication result.
#
# History:   C++ version written by Tim Mattson, August 2010
#            Modified by Simon McIntosh-Smith, September 2011
#            Modified by Tom Deakin and Simon McIntosh-Smith, October 2012
#            Ported to Python by Tom Deakin, July 2013
#            Ported to Julia by Jake Bolewski, Nov 2013

import OpenCL
const cl = OpenCL

# get the directory of this file
# (used for test runner)
src_dir = dirname(Base.source_path())

#### Definitions ###

# Order of the square matrices A, B and C
ORDER = 512

# A elemetns are constant and equal to AVAL
AVAL = 3.0

# B elemetns are constant and equal to BVAL
BVAL = 5.0

# tolerance used in floating point comparisons
TOL = 0.001

# Max dim for NDRange
DIM = 2

# number of times to do each multiplication
COUNT = 1

# Helper functions
include("helper.jl")

# A[N,P], B[P M], C[N,M]
Ndim = ORDER
Pdim = ORDER
Mdim = ORDER

# Number of elements in the matrix
sizeA = Ndim * Pdim
sizeB = Pdim * Mdim
sizeC = Ndim * Mdim

# Number of elements in the matrix
h_A = fill(float32(AVAL), sizeA)
h_B = fill(float32(BVAL), sizeB)
h_C = Array(Float32, sizeC)

# %20 improvment using @inbounds
function seq_mat_mul_sdot{T}(Mdim::Int, Ndim::Int, Pdim::Int,
                             A::Array{T}, B::Array{T}, C::Array{T})
    for i in 1:Ndim
        for j in 1:Mdim
            tmp = zero(Float32)
            for k in 1:Pdim
                @inbounds tmp += A[(i-1)*Ndim+k] * B[(k-1)*Pdim+j]
            end
            @inbounds C[(i-1)*Ndim+j] = tmp
        end
    end
end

info("=== Julia, matix mult (dot prod), order $ORDER ===")

# force compilation
seq_mat_mul_sdot(Mdim, Ndim, Pdim, h_A, h_B, h_C)

for i in 1:COUNT
    fill!(h_C, 0.0)
    t1 = time()
    seq_mat_mul_sdot(Mdim, Ndim, Pdim, h_A, h_B, h_C)
    t2 = time()
    results(Mdim, Ndim, Pdim, h_C, t2 - t1)
end

# set up OpenCL
ctx = cl.create_some_context()

# You can enable profiling events on the queue
# by calling the constructor with the :profile flag
queue = cl.CmdQueue(ctx, :profile)

# create OpenCL Buffers
d_a = cl.Buffer(Float32, ctx, (:r,:copy), hostbuf=h_A)
d_b = cl.Buffer(Float32, ctx, (:r,:copy), hostbuf=h_B)
d_c = cl.Buffer(Float32, ctx, :w, length(h_C))

#--------------------------------------------------------------------------------
# OpenCL matrix multiplication ... Naive
#--------------------------------------------------------------------------------

kernel_source = open(readall, joinpath(src_dir, "C_elem.cl"))
prg  = cl.Program(ctx, source=kernel_source) |> cl.build!
mmul = cl.Kernel(prg, "mmul")

info("=== OpenCL, matrix mult, C(i, j) per work item, order $Ndim ====")

for i in 1:COUNT
    fill!(h_C, 0.0)
    evt = cl.call(queue, mmul, (Ndim, Mdim), nothing,
                  int32(Mdim), int32(Ndim), int32(Pdim),
                  d_a, d_b, d_c)
    # profiling events are measured in ns
    run_time = evt[:profile_duration] / 1e9
    cl.copy!(queue, h_C, d_c)
    results(Mdim, Ndim, Pdim, h_C, run_time)
end

#--------------------------------------------------------------------------------
# OpenCL matrix multiplication ... C row per work item
#--------------------------------------------------------------------------------

kernel_source = open(readall, joinpath(src_dir, "C_row.cl"))
prg  = cl.Program(ctx, source=kernel_source) |> cl.build!
mmul = cl.Kernel(prg, "mmul")

info("=== OpenCL, matrix mult, C row per work item, order $Ndim ====")

for i in 1:COUNT
    fill!(h_C, 0.0)
    evt = cl.call(queue, mmul, (Ndim,), (int(ORDER/16),),
                  int32(Mdim), int32(Ndim), int32(Pdim),
                  d_a, d_b, d_c)
    # profiling events are measured in ns
    run_time = evt[:profile_duration] / 1e9
    cl.copy!(queue, h_C, d_c)
    results(Mdim, Ndim, Pdim, h_C, run_time)
end

#--------------------------------------------------------------------------------
# OpenCL matrix multiplication ... C row per work item, A row in pivate memory
#--------------------------------------------------------------------------------
kernel_source = open(readall, joinpath(src_dir, "C_row_priv_block.cl"))
prg  = cl.Program(ctx, source=kernel_source) |> cl.build!
mmul = cl.Kernel(prg, "mmul")

info("=== OpenCL, matrix mult, C row, priv A, B, cols loc, order $Ndim ====")

for i in 1:COUNT
    fill!(h_C, 0.0)
    localmem = cl.LocalMem(Float32, Pdim)

    mmul_ocl = mmul[queue, (Ndim,), (div(ORDER, 16),)]

    evt = mmul_ocl(int32(Mdim), int32(Ndim), int32(Pdim), d_a, d_b, d_c, localmem)

    # profiling events are measured in ns
    run_time = evt[:profile_duration] / 1e9
    cl.copy!(queue, h_C, d_c)
    results(Mdim, Ndim, Pdim, h_C, run_time)
end

#--------------------------------------------------------------------------------
# OpenCL matrix multiplication ... C row per work item, A row pivate, B col local
#--------------------------------------------------------------------------------
kernel_source = open(readall, joinpath(src_dir, "C_block_form.cl"))
prg  = cl.Program(ctx, source=kernel_source) |> cl.build!
mmul = cl.Kernel(prg, "mmul")

info("=== OpenCL, matrix mult, A and B in block form in local memory, order $Ndim ====")
blocksize = 16

for i in 1:COUNT
    fill!(h_C, float32(0.0))
    localmem1 = cl.LocalMem(Float32, blocksize^2)
    localmem2 = cl.LocalMem(Float32, blocksize^2)
    evt = cl.call(queue, mmul, (Ndim,), (int(ORDER/16),),
                  int32(Mdim), int32(Ndim), int32(Pdim),
                  d_a, d_b, d_c, localmem1, localmem2)
    # profiling events are measured in ns
    run_time = evt[:profile_duration] / 1e9
    cl.copy!(queue, h_C, d_c)
    results(Mdim, Ndim, Pdim, h_C, run_time)
end
