using Arpack, LinearMaps, LinearAlgebra

# ----------------------------------------------------
# Positive Semidefinite Cone
# ----------------------------------------------------
mutable struct PsdConeTriangleLanczos{T} <: AbstractConvexCone{T}
  dim::Int
  n::Int
  positive_subspace::Bool
  X::Matrix{T}  # Matrix under projection
  Z::UpdatableQ{T}  # Subspace
  z_rem::Matrix{T} # Largest eigenvector(s) from the discarded subspace (N.B. z_rem might have been appended to Z)
  λ::Vector{T} # Previous eigenvalue estimates of the subspace
  buffer_size::Int
  iter_number::Int
  # History
  residual_history::Vector{T}
  λ_rem_history::Vector{T}
  subspace_dim_history::Vector{Int}
  λ_rem_multiplications::Vector{Int}

  function PsdConeTriangleLanczos{T}(dim::Int) where{T}
      dim >= 0       || throw(DomainError(dim, "dimension must be nonnegative"))
      n = Int(1/2*(sqrt(8*dim + 1) - 1)) # Solution of (n^2 + n)/2 = length(x) obtained by WolframAlpha
      n*(n + 1)/2 == dim || throw(DomainError(dim, "dimension must be a square"))
      new(dim, n, true,
        zeros(T, n, n), # X
        UpdatableQ(zeros(T, n, 0)), # Ζ
        randn(T, n, 1),
        zeros(T, 0),
        3, # buffer_size
        0, # iter_number
        zeros(T, 0), # residual_history
        zeros(T, 0), # λ_rem_history
        zeros(Int, 0), # subspace_dim_history
        zeros(Int, 0) # λ_rem_multiplications
        )
  end
end
PsdConeTriangleLanczos(dim) = PsdConeTriangleLanczos{DefaultFloat}(dim)

function project_to_nullspace!(x::AbstractVector{T}, tmp::AbstractVector{T}, U::Array{T}) where {T}
  # Project x to the nullspace of U', i.e. x .= (I - U*U')*x
  # tmp is a vector used in intermmediate calculations
  mul!(tmp, U', x)
  BLAS.gemv!('N', -one(T), U, tmp, one(T), x)
end

function estimate_λ_rem(X::Symmetric{T, Matrix{T}}, U::Matrix{T}, x0::Vector{T}=randn(T, size(X, 1)), n::Int=1) where T
  # Estimates largest eigenvalue of the Symmetric X on the subspace we discarded
  # Careful, we need to enforce all iterates to be orthogonal to the range of U
  tmp = zeros(T, size(U, 2))
  offset = T(100)
  function custom_mul!(y::AbstractVector{T}, x::AbstractVector{T}) where {T}
      # Performs y .= (I - U*U')*X*x
      # y .= X*x - U*(U'*(X*x))
      project_to_nullspace!(x, tmp, U)
      mul!(y, X, x)
      project_to_nullspace!(y, tmp, U)
      axpy!(offset, x, y)
  end
  # V = Matrix(qr(U).Q*Matrix(I, size(U, 1), size(U, 1)))[:, size(U, 2)+1:end]
  # @show sort(eigvals(Symmetric(V'*(X + offset*I)*V)))
  project_to_nullspace!(x0, tmp, U)
  A = LinearMap{T}(custom_mul!, size(X, 1); ismutating=true, issymmetric=true)
  λ_rem, v_rem, nconv, niter, nmult, resid = eigs(A, nev=n, ncv=20, which=:LR, tol=1e-1, v0=x0)
  return λ_rem .- offset, v_rem, nmult
end

function expand_subspace(X::Symmetric{T, Matrix{T}}, cone::PsdConeTriangleLanczos{T}) where {T}
  m = size(cone.Z.Q1, 2)
  XZ = X*cone.Z.Q1
  add_columns!(cone.Z, XZ)

  XW = [XZ X*view(cone.Z.Q, :, m+1:size(cone.Z.Q1, 2))]
  # @assert norm(XW - X*cone.Z.Q1) <= 1e-9
  return cone.Z.Q1, XW
end

function project!(x::AbstractArray, cone::PsdConeTriangleLanczos{T}) where{T}
  n = cone.n
  cone.iter_number += 1

  if mod(cone.iter_number, 40) == 0 || size(cone.Z.Q1, 2) == 0 || size(cone.Z.Q1, 2) >= cone.n/2 || n == 1
      append!(cone.λ_rem_multiplications, 0)
      return project_exact!(x, cone)
  end

  if !cone.positive_subspace
      @. x = -x
  end
  populate_upper_triangle!(cone.X, x)
  X = Symmetric(cone.X)

  W, XW = expand_subspace(X, cone)
  Xsmall = W'*XW
  l, V, first_positive, first_negative = eigen_sorted(Symmetric(Xsmall), 1e-10);

  # Positive Ritz pairs
  Vp = V[:, first_positive:end]
  U = W*Vp; λ = l[first_positive:end];

  buffer_idx = max(first_negative-cone.buffer_size-1,1):max(first_negative,0)
  Ub = W*V[:, buffer_idx]; λb = l[buffer_idx]

  # Residual Calculation
  R = XW*Vp - U*Diagonal(λ)
  # R = X*U - U*Diagonal(λ)
  append!(cone.residual_history, norm(R))
  set_Q!(cone.Z, U)
  add_columns!(cone.Z, Ub) # Buffer
  cone.λ = [λ; λb]

  # Important: why not [U Ub]?
  λ_rem, cone.z_rem, nmult = estimate_λ_rem(X, U, cone.z_rem[:, 1])
  # λ_rem = [0.0]; cone.z_rem = randn(size(U, 1), 1); nmult = 0
  append!(cone.λ_rem_multiplications, nmult)
  append!(cone.λ_rem_history, maximum(λ_rem))
  λ_rem .= max.(λ_rem, 0.0)
  eig_sum = sum(λ_rem).^2 + (n - size(W, 2) - length(λ_rem))*minimum(λ_rem).^2
  residual = sqrt(2*norm(R)^2 + eig_sum)

  if true # || any(λ_rem .> 0)
    append!(cone.λ, λ_rem[λ_rem .> 0]) # Positive eigenvalues, buffer and remainder's eigenvalue (the last one will be very crude)
    add_columns!(cone.Z, cone.z_rem[:, λ_rem .> 0])
  end
  append!(cone.subspace_dim_history, size(cone.Z.Q1, 2))
  
  # Reconstruct projection
  rmul!(U, Diagonal(sqrt.(λ)))
  if cone.positive_subspace
    BLAS.syrk!('U', 'N', 1.0, U, 0.0, cone.X)
  else
    BLAS.syrk!('U', 'N', 1.0, U, -1.0, cone.X)
  end

  extract_upper_triangle!(cone.X, x)
end

function project_exact!(x::AbstractArray{T}, cone::PsdConeTriangleLanczos{T}) where{T}
  n = cone.n

  # handle 1D case
  if length(x) == 1
      x = max.(x,zero(T))
  else
      # symmetrized square view of x
      populate_upper_triangle!(cone.X, x)

      # compute eigenvalue decomposition
      # then round eigs up and rebuild
      λ, U  = eigen!(Symmetric(cone.X))
      Up = U[:, λ .> 0]
      sqrt_λp = sqrt.(λ[λ .> 0])
      if length(sqrt_λp) > 0
          rmul!(Up, Diagonal(sqrt_λp))
          BLAS.syrk!('U', 'N', 1.0, Up, 0.0, cone.X)
          # X = Up*Diagonal(λ[λ .> 0])*Up'
      else
          X .= 0
          return nothing
          #ToDo: Handle this case with lanczos
      end
      extract_upper_triangle!(cone.X, x)
      
      # Save the subspace that we will be tracking
      if sum(λ .> 0) <= sum(λ .< 0)
        cone.positive_subspace = true
      else
        λ .= -λ # Equivalent to considering -X instead of X
        cone.positive_subspace = false
      end
      sorted_idx = sortperm(λ)
      idx = findfirst(λ[sorted_idx] .> 0) # First positive index
      if isa(idx, Nothing)
          idx = length(λ) + 1
      end
      # Take also a few vectors from the discarted eigenspace
      idx = max(idx - cone.buffer_size, 1)
      set_Q!(cone.Z, U[:, sorted_idx[idx:end]])
      cone.λ = λ[sorted_idx[idx:end]]
  end
  append!(cone.residual_history, 0.0)
  append!(cone.λ_rem_history, 0.0)
  append!(cone.subspace_dim_history, size(cone.Z.Q1, 2))
  cone.z_rem .= randn(n)
  return nothing
end

function eigen_sorted(A::Symmetric, tol::AbstractFloat=0.0)
  λ, U = eigen(A)
  sorted_idx = sortperm(λ)
  λ = λ[sorted_idx]
  U = U[:, sorted_idx]
  first_positive = findfirst(λ[sorted_idx] .> tol)
  if isa(first_positive, Nothing)
      first_positive = length(λ) + 1
  end
  first_negative = findfirst(λ[sorted_idx] .< tol)
  if isa(first_negative, Nothing)
      first_negative = 0
  end

  return λ, U, first_positive, first_negative
end