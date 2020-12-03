"""
    enforce_boundary_conditions(x, xₗ, xᵣ, ::Type{Bounded})

If a particle with position `x` and domain `xₗ < x < xᵣ` goes through the edge of the domain
along a `Bounded` dimension, put them back at the wall.
"""
@inline function enforce_boundary_conditions(::Type{Bounded}, x, xₗ, xᵣ, restitution)
    x > xᵣ && return xᵣ - (x - xᵣ) * restitution
    x < xₗ && return xₗ + (xₗ - x) * restitution
    return x
end

"""
    enforce_boundary_conditions(x, xₗ, xᵣ, ::Type{Periodic})

If a particle with position `x` and domain `xₗ < x < xᵣ` goes through the edge of the domain
along a `Periodic` dimension, put them on the other side.
"""
@inline function enforce_boundary_conditions(::Type{Periodic}, x, xₗ, xᵣ, restitution)
    x > xᵣ && return xₗ + (x - xᵣ)
    x < xₗ && return xᵣ - (xₗ - x)
    return x
end

@kernel function _advect_particles!(particles, restitution, grid::RegularCartesianGrid{FT, TX, TY, TZ}, Δt, velocities) where {FT, TX, TY, TZ}
    p = @index(Global)

    # Advect particles using forward Euler.
    @inbounds particles.x[p] += interpolate(velocities.u, Face, Cell, Cell, grid, particles.x[p], particles.y[p], particles.z[p]) * Δt
    @inbounds particles.y[p] += interpolate(velocities.v, Cell, Face, Cell, grid, particles.x[p], particles.y[p], particles.z[p]) * Δt
    @inbounds particles.z[p] += interpolate(velocities.w, Cell, Cell, Face, grid, particles.x[p], particles.y[p], particles.z[p]) * Δt

    # Enforce boundary conditions for particles.
    @inbounds particles.x[p] = enforce_boundary_conditions(TX, particles.x[p], grid.xF[1], grid.xF[grid.Nx], restitution)
    @inbounds particles.y[p] = enforce_boundary_conditions(TY, particles.y[p], grid.yF[1], grid.yF[grid.Ny], restitution)
    @inbounds particles.z[p] = enforce_boundary_conditions(TZ, particles.z[p], grid.zF[1], grid.zF[grid.Nz], restitution)
end

@kernel function update_field_property!(particle_property, particles, grid, field, LX, LY, LZ)
    p = @index(Global)

    @inbounds particle_property[p] = interpolate(field, LX, LY, LZ, grid, particles.x[p], particles.y[p], particles.z[p])
end

function advect_particles!(lagrangian_particles, model, Δt)
    workgroup = min(length(lagrangian_particles), MAX_THREADS_PER_BLOCK)
    worksize = length(lagrangian_particles)
    advect_particles_kernel! = _advect_particles!(device(model.architecture), workgroup, worksize)

    advect_particles_event = advect_particles_kernel!(lagrangian_particles.particles, lagrangian_particles.restitution, model.grid, Δt,
                                                      datatuple(model.velocities),
                                                      dependencies=Event(device(model.architecture)))

    wait(device(model.architecture), advect_particles_event)

    events = []

    for (field_name, tracked_field) in pairs(lagrangian_particles.tracked_fields)
        compute!(tracked_field)
        particle_property = getproperty(lagrangian_particles.particles, field_name)
        LX, LY, LZ = location(tracked_field)

        update_field_property_kernel! = update_field_property!(device(model.architecture), workgroup, worksize)

        update_event = update_field_property_kernel!(particle_property, lagrangian_particles.particles, model.grid,
                                                     datatuple(tracked_field), LX, LY, LZ,
                                                     dependencies=Event(device(model.architecture)))
        push!(events, update_event)
    end

    wait(device(model.architecture), MultiEvent(Tuple(events)))

    return nothing
end

advect_particles!(::Nothing, model, Δt) = nothing

advect_particles!(model, Δt) = advect_particles!(model.particles, model, Δt)