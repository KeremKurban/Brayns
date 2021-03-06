/* Copyright (c) 2015-2018, EPFL/Blue Brain Project
 * All rights reserved. Do not distribute without permission.
 * Responsible Author: Jonas Karlsson <jonas.karlsson@epfl.ch>
 *
 * Based on OSPRay implementation
 *
 * This file is part of Brayns <https://github.com/BlueBrain/Brayns>
 *
 * This library is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License version 3.0 as published
 * by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// ospray
#include "ospray/SDK/common/Model.ih"
#include "ospray/SDK/common/Ray.ih"
#include "ospray/SDK/geometry/Geometry.ih"
#include "ospray/SDK/math/box.ih"
#include "ospray/SDK/math/vec.ih"

// embree
#include "embree2/rtcore.isph"
#include "embree2/rtcore_geometry_user.isph"
#include "embree2/rtcore_scene.isph"

#include "utils/SafeIncrement.ih"

#define SDF_TYPE_SPHERE 0
#define SDF_TYPE_PILL 1
#define SDF_TYPE_CONE_PILL 2
#define SDF_TYPE_CONE_PILL_SIGMOID 3

#define SDF_BLEND_FACTOR 0.1
#define SDF_BLEND_LERP_FACTOR 0.2

#define SDF_EPSILON 0.000001

/////////////////////////////////////////////////////////////////////////////

// https://en.wikipedia.org/wiki/Smoothstep
inline float smootherstep(const float x)
{
    return x * x * x * (x * (x * 6 - 15) + 10);
}

inline float sdSphere(const vec3f& p, const vec3f c, float r)
{
    return length(p - c) - r;
}

inline float sdCapsule(const vec3f& p, const vec3f a, const vec3f b, float r)
{
    const vec3f pa = p - a, ba = b - a;
    const float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

inline float mix(const float x, const float y, const float a)
{
    return x * (1.f - a) + y * a;
}

// polynomial smooth min (k = 0.1);
inline float sminPoly(const float a, const float b, const float k)
{
    const float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

inline float sdConePill(const vec3f& p, const vec3f p0, const vec3f p1,
                        const float radius_bottom, const float radius_top,
                        const bool useSigmoid)
{
    const vec3f v = p1 - p0;
    const vec3f w = p - p0;

    const float c1 = dot(w, v);
    if (c1 <= 0)
        return length(p - p0) - radius_bottom;

    const float c2 = dot(v, v);
    if (c2 <= c1)
        return length(p - p1) - radius_top;

    const float b = c1 / c2;
    const vec3f Pb = p0 + b * v;

    const float thicknessAt = mix(radius_bottom, radius_top, b);
    const float thickness =
        useSigmoid
            ? 0.5 * (thicknessAt +
                     mix(radius_bottom, radius_top, smootherstep(b)))
            : thicknessAt;

    return length(p - Pb) - thickness;
}

// AABB-Ray intersection ( http://prideout.net/blog/?p=64 ).
inline varying bool intersectBox(Ray& ray, const vec3f aabbMin,
                                 const vec3f aabbMax, float& t0, float& t1)
{
    const float epsilon = SDF_EPSILON;

    Ray r = ray;
    // We need to avoid division by zero in "vec3 invR = 1.0 / r.Dir;"
    if (r.dir.x == 0)
        r.dir.x = epsilon;

    if (r.dir.y == 0)
        r.dir.y = epsilon;

    if (r.dir.z == 0)
        r.dir.z = epsilon;

    const vec3f invR = 1.f / r.dir;
    const vec3f tbot = invR * (aabbMin - r.org);
    const vec3f ttop = invR * (aabbMax - r.org);
    const vec3f tmin = min(ttop, tbot);
    const vec3f tmax = max(ttop, tbot);
    vec2f t = make_vec2f(max(tmin.x, tmin.y), max(tmin.x, tmin.z));
    t0 = max(t.x, t.y);
    t = make_vec2f(min(tmax.x, tmax.y), min(tmax.x, tmax.z));
    t1 = min(t.x, t.y);
    return (t0 <= t1);
}

/////////////////////////////////////////////////////////////////////////////

// NOTE: This layout must match exactly the 'SDFGeometry' struct in
// 'SDFGeometry.h'
struct ExtendedSDFGeometry
{
    vec3f center;
    vec3f p0;
    vec3f p1;
    vec2f textureCoords;
    float radius;
    float radius_tip;
    float timestamp;
    uint64 neighboursIndex;
    uint8 numNeighbours;
    uint8 type;
};

struct ExtendedSDFGeometries
{
    uniform Geometry geometry;

    uniform uint64* uniform geometryRefs;
    uniform uint64* uniform neighbours;
    uniform ExtendedSDFGeometry* uniform geometries;

    uint64 numExtendedSDFGeometries;
    uniform bool useSafeIncrement;
};

DEFINE_SAFE_INCREMENT(ExtendedSDFGeometry);
DEFINE_SAFE_INCREMENT(uint64);

/////////////////////////////////////////////////////////////////////////////

uniform uint64 primToIdx(uniform ExtendedSDFGeometries* uniform geometry,
                         uniform uint64 primID)
{
    return *safeIncrement(geometry->useSafeIncrement, geometry->geometryRefs,
                          primID);
}

varying uint64 primToIdxVarying(uniform ExtendedSDFGeometries* uniform geometry,
                                varying uint64 primID)
{
    return *safeIncrement(geometry->useSafeIncrement, geometry->geometryRefs,
                          primID);
}

uniform uint64 getNeighbourIdx(uniform ExtendedSDFGeometries* uniform geometry,
                               uniform uint64 startIdx, uniform uint64 neighIdx)
{
    return *safeIncrement(geometry->useSafeIncrement, geometry->neighbours,
                          startIdx + neighIdx);
}

uniform ExtendedSDFGeometry uniform getGeometry(
    uniform ExtendedSDFGeometries* uniform geometry, uniform uint64 idx)
{
    return *safeIncrement(geometry->useSafeIncrement, geometry->geometries,
                          idx);
}

varying ExtendedSDFGeometry getGeometryVarying(
    uniform ExtendedSDFGeometries* uniform geometry, varying uint64 idx)
{
    return *safeIncrement(geometry->useSafeIncrement, geometry->geometries,
                          idx);
}

static void ExtendedSDFGeometries_postIntersect(
    uniform Geometry* uniform geometry, uniform Model* uniform model,
    varying DifferentialGeometry& dg, const varying Ray& ray,
    uniform int64 flags)
{
    uniform ExtendedSDFGeometries* uniform this =
        (uniform ExtendedSDFGeometries * uniform)geometry;
    dg.geometry = geometry;
#if ((OSPRAY_VERSION_MAJOR == 1) && (OSPRAY_VERSION_MINOR < 5))
    dg.material = geometry->material;
#endif
    vec3f Ng = ray.Ng;
    vec3f Ns = Ng;

    { // Set texture coordinates
        const uint32 idx = primToIdxVarying(this, ray.primID);
        varying ExtendedSDFGeometry geom = getGeometryVarying(this, idx);

        dg.st.x = geom.textureCoords.x;
        dg.st.y = geom.textureCoords.y;
    }

    if (flags & DG_NORMALIZE)
    {
        Ng = normalize(Ng);
        Ns = normalize(Ns);
    }
    if (flags & DG_FACEFORWARD)
    {
        if (dot(ray.dir, Ng) >= 0.f)
            Ng = neg(Ng);
        if (dot(ray.dir, Ns) >= 0.f)
            Ns = neg(Ns);
    }

    dg.Ng = Ng;
    dg.Ns = Ns;
}

void ExtendedSDFGeometries_bounds(uniform ExtendedSDFGeometries* uniform
                                      geometry,
                                  uniform uint64 primID, uniform box3fa& bbox)
{
    const uniform int idx = primToIdx(geometry, primID);
    uniform ExtendedSDFGeometry uniform geom = getGeometry(geometry, idx);

    if (geom.type == SDF_TYPE_SPHERE)
    {
        bbox = make_box3fa(geom.center - make_vec3f(geom.radius),
                           geom.center + make_vec3f(geom.radius));
    }
    else if (geom.type == SDF_TYPE_CONE_PILL || geom.type == SDF_TYPE_PILL ||
             geom.type == SDF_TYPE_CONE_PILL_SIGMOID)
    {
        uniform vec3f minV =
            make_vec3f(min(geom.p0.x, geom.p1.x), min(geom.p0.y, geom.p1.y),
                       min(geom.p0.z, geom.p1.z));

        uniform vec3f maxV =
            make_vec3f(max(geom.p0.x, geom.p1.x), max(geom.p0.y, geom.p1.y),
                       max(geom.p0.z, geom.p1.z));

        bbox = make_box3fa(minV - make_vec3f(geom.radius),
                           maxV + make_vec3f(geom.radius));
    }
}

inline float calcGeometryDistance(uniform ExtendedSDFGeometries* uniform
                                      geometry,
                                  vec3f& p, uniform int32 idx)
{
    uniform ExtendedSDFGeometry geom = getGeometry(geometry, idx);

    if (geom.type == SDF_TYPE_SPHERE)
        return sdSphere(p, geom.center, geom.radius);
    else if (geom.type == SDF_TYPE_PILL)
        return sdCapsule(p, geom.p0, geom.p1, geom.radius);
    else if (geom.type == SDF_TYPE_CONE_PILL ||
             geom.type == SDF_TYPE_CONE_PILL_SIGMOID)
    {
        return sdConePill(p, geom.p0, geom.p1, geom.radius, geom.radius_tip,
                          geom.type == SDF_TYPE_CONE_PILL_SIGMOID);
    }

    return -1.0;
}

inline float map(uniform ExtendedSDFGeometries* uniform geometry, vec3f& p,
                 uniform uint64 primID)
{
    uniform int idx = primToIdx(geometry, primID);
    uniform ExtendedSDFGeometry uniform geom = getGeometry(geometry, idx);

    float d = calcGeometryDistance(geometry, p, idx);
    const float r0 = geom.radius;

    const uint8 numNeighs = geom.numNeighbours;

    for (uniform int i = 0; i < numNeighs; i++)
    {
        uniform int32 nei_i =
            getNeighbourIdx(geometry, geom.neighboursIndex, i);

        uniform ExtendedSDFGeometry geomNei = getGeometry(geometry, nei_i);

        const float dOther = calcGeometryDistance(geometry, p, nei_i);
        const float r1 = geomNei.radius;
        const float blendFactor =
            mix(min(r0, r1), max(r0, r1), SDF_BLEND_LERP_FACTOR);

        d = sminPoly(dOther, d, blendFactor * SDF_BLEND_FACTOR);
    }

    return d;
}

inline vec3f calcNormal(uniform ExtendedSDFGeometries* uniform geometry,
                        const float eps, const vec3f& pos,
                        uniform uint64 primID)
{
    const float x0 = map(geometry, pos + make_vec3f(eps, 0.f, 0.f), primID);
    const float x1 = map(geometry, pos - make_vec3f(eps, 0.f, 0.f), primID);
    const float y0 = map(geometry, pos + make_vec3f(0.f, eps, 0.f), primID);
    const float y1 = map(geometry, pos - make_vec3f(0.f, eps, 0.f), primID);
    const float z0 = map(geometry, pos + make_vec3f(0.f, 0.f, eps), primID);
    const float z1 = map(geometry, pos - make_vec3f(0.f, 0.f, eps), primID);

    return normalize(make_vec3f(x0 - x1, y0 - y1, z0 - z1));
}

inline float intersect(uniform ExtendedSDFGeometries* uniform geometry,
                       const vec3f& ro, const vec3f& rd, uniform uint64 primID)
{
    Ray ray;
    ray.dir = rd;
    ray.org = ro;

    uniform int idx = primToIdx(geometry, primID);
    uniform box3fa bbox;

    ExtendedSDFGeometries_bounds(geometry, primID, bbox);

    float t0_pre, t1_pre;
    const vec3f aabbMin = make_vec3f(bbox.lower);
    const vec3f aabbMax = make_vec3f(bbox.upper);

    if (!intersectBox(ray, aabbMin, aabbMax, t0_pre, t1_pre))
        return -1;

    const float t0 = t0_pre;
    const float t1 = t1_pre;

    const int samplesPerRay = 100;
    float t = t0;
    float res = -1.f;
    float h = 1.f;
    for (int i = 0; i < samplesPerRay; ++i)
    {
        if (h < SDF_EPSILON || t > t1)
            break;
        h = map(geometry, ro + rd * t, primID);
        res = t;
        t += h;
    }
    if (t > t1)
        res = -1.f;
    return res;
}

void ExtendedSDFGeometries_intersect(uniform ExtendedSDFGeometries* uniform
                                         geometry,
                                     varying Ray& ray, uniform uint64 primID)
{
    uniform int idx = primToIdx(geometry, primID);
    uniform ExtendedSDFGeometry geom = getGeometry(geometry, idx);

    if (ray.time > 0 && geom.timestamp > ray.time)
        return;

    const float t_in = intersect(geometry, ray.org, ray.dir, primID);
    if (t_in > 0 && t_in > ray.t0 && t_in < ray.t)
    {
        vec3f pos = ray.org + t_in * ray.dir;

        ray.primID = primID;
        ray.geomID = geometry->geometry.geomID;
        ray.t = t_in;
        ray.Ng = calcNormal(geometry, getIntersectionError(ray.org, t_in), pos,
                            primID);
    }
}

export void* uniform ExtendedSDFGeometries_create(void* uniform cppEquivalent)
{
    uniform ExtendedSDFGeometries* uniform geom =
        uniform new uniform ExtendedSDFGeometries;
    Geometry_Constructor(&geom->geometry, cppEquivalent,
                         ExtendedSDFGeometries_postIntersect, 0, 0, 0);
    return geom;
}

export void ExtendedSDFGeometriesGeometry_set(
    void* uniform _geom, void* uniform _model, void* uniform data,
    int uniform numExtendedSDFGeometries, void* uniform neighbours,
    int uniform numNeighbours, void* uniform geometries)
{
    uniform ExtendedSDFGeometries* uniform geom =
        (uniform ExtendedSDFGeometries * uniform)_geom;
    uniform Model* uniform model = (uniform Model * uniform)_model;

    uniform uint32 geomID =
        rtcNewUserGeometry(model->embreeSceneHandle, numExtendedSDFGeometries);

    geom->geometry.model = model;
    geom->geometry.geomID = geomID;
    geom->numExtendedSDFGeometries = numExtendedSDFGeometries;
    geom->geometryRefs = (uniform uint64 * uniform)data;
    geom->neighbours = (uniform uint64 * uniform)neighbours;
    geom->geometries = (uniform ExtendedSDFGeometry * uniform)geometries;

    // NOTE: geom->data is always smaller than geom->geometries
    geom->useSafeIncrement =
        needsSafeIncrement(geom->geometries, numExtendedSDFGeometries) ||
        needsSafeIncrement(geom->neighbours, numNeighbours);

    rtcSetUserData(model->embreeSceneHandle, geomID, geom);
    rtcSetBoundsFunction(model->embreeSceneHandle, geomID,
                         (uniform RTCBoundsFunc)&ExtendedSDFGeometries_bounds);
    rtcSetIntersectFunction(
        model->embreeSceneHandle, geomID,
        (uniform RTCIntersectFuncVarying)&ExtendedSDFGeometries_intersect);
    rtcSetOccludedFunction(
        model->embreeSceneHandle, geomID,
        (uniform RTCOccludedFuncVarying)&ExtendedSDFGeometries_intersect);
    rtcEnable(model->embreeSceneHandle, geomID);
}
