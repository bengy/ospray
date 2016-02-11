// ======================================================================== //
// Copyright 2009-2016 Intel Corporation                                    //
//                                                                          //
// Licensed under the Apache License, Version 2.0 (the "License");          //
// you may not use this file except in compliance with the License.         //
// You may obtain a copy of the License at                                  //
//                                                                          //
//     http://www.apache.org/licenses/LICENSE-2.0                           //
//                                                                          //
// Unless required by applicable law or agreed to in writing, software      //
// distributed under the License is distributed on an "AS IS" BASIS,        //
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. //
// See the License for the specific language governing permissions and      //
// limitations under the License.                                           //
// ======================================================================== //

#include "ospray/fb/FrameBuffer.ih"
#include "ospray/render/util.ih"
#include "ospray/common/Model.ih"
#include "ospray/texture/Texture2D.ih"
#include "ospray/lights/Light.ih"
#include "ospray/render/Renderer.ih"
#include "ospray/math/random.ih"
#include "ospray/math/sampling.ih"
#include "ospray/math/LinearSpace.ih"

#include "ospray/volume/DataDistributedBlockedVolume.ih"

#include "SciVisMaterial.ih"

#define ALPHA_THRESHOLD (.05f)

// Data types
//////////////////////////////////////////////////////////////////////////////

struct SciVisRenderer
{
  Renderer super;

  const uniform Light *uniform *uniform lights;
  uint32 numLights;

  bool  shadowsEnabled;

  int   maxDepth;

  int   aoSamples;
  float aoRayLength;
  float aoWeight;
};

struct SciVisShadingInfo
{
  float d ;
  float Ns;
  vec3f Kd;
  vec3f Ks;
  float local_opacity;
  float path_opacity;

  vec3f geometryColor;
};

struct PassInfo {
  // region to integrate over in this pass
  varying region1f region;
  // block to use in this pass - NULL for 'everything other than blocks'
  DDBVolumeBlock *uniform block;
  // blend in background color when ray misses
  uniform bool useBG;
};

// Function definitions
///////////////////////////////////////////////////////////////////////////////

inline void initShadingInfo(varying SciVisShadingInfo &info)
{
  info.d  = 1.f;
  info.Ns = 0.f;
  info.Kd = make_vec3f(0.f);
  info.Ks = make_vec3f(0.f);
  info.local_opacity = 0.f;

  info.geometryColor = make_vec3f(0.f);
}

// Material functions //

inline void shadeMaterials(const varying DifferentialGeometry &dg,
                           varying SciVisShadingInfo &info)
{
  uniform SciVisMaterial *scivisMaterial =
      (uniform SciVisMaterial *)dg.material;

  info.geometryColor = make_vec3f(dg.color);

  // Get each term from the material //
  if (!scivisMaterial) {
    info.d = dg.color.w;
    info.Kd = make_vec3f(dg.color);
  } else {
    foreach_unique (mat in scivisMaterial) {
      // textures modify (mul) values, see
      //   http://paulbourke.net/dataformats/mtl/
      info.d = mat->d * get1f(mat->map_d, dg.st, 1.f);
      info.Kd = mat->Kd * make_vec3f(dg.color);
      if (mat->map_Kd) {
        vec4f Kd_from_map = get4f(mat->map_Kd, dg.st);
        info.Kd = info.Kd * make_vec3f(Kd_from_map);
        info.d *= Kd_from_map.w;
      }
      info.Ks = mat->Ks * get3f(mat->map_Ks, dg.st, make_vec3f(1.f));
      info.Ns = mat->Ns * get1f(mat->map_Ns, dg.st, 1.f);

      if (mat->volume) {
        const float sample = mat->volume->computeSample(mat->volume, dg.P);
        info.geometryColor = info.geometryColor * mat->volume->transferFunction->getColorForValue(mat->volume->transferFunction, sample);
      }
    }
  }
}

// AO functions //

inline float calculateAO(const uniform SciVisRenderer *uniform self,
                         const varying vec3i &sampleID,
                         const varying DifferentialGeometry &dg)
{
  const int accumID = sampleID.z;
  const int ix = sampleID.x;
  const int iy = sampleID.y;

  // init TEA RNG //
  RandomTEA rng_state;
  varying RandomTEA* const uniform rng = &rng_state;
  RandomTEA__Constructor(rng, (self->super.fb->size.x * iy) + ix, accumID);

  int hits = 0;
  const linear3f localToWorld = frame(dg.Ns);

  for (uniform int i = 0; i < self->aoSamples; i++) {
    const vec2f s = RandomTEA__getFloats(rng);
    const vec3f local_ao_dir = cosineSampleHemisphere(s);
    const vec3f ao_dir = localToWorld * local_ao_dir;

    Ray ao_ray;
    setRay(ao_ray, dg.P + (1e-3f * dg.Ns), ao_dir,
           self->super.epsilon, self->aoRayLength);
    if (dot(ao_ray.dir, dg.Ns) < 0.05f || isOccluded(self->super.model,ao_ray))
      hits++;
  }

  return 1.0f - (float)hits/self->aoSamples;
}

inline void shadeAO(const uniform SciVisRenderer *uniform self,
                    const varying vec3i &sampleID,
                    const varying DifferentialGeometry &dg,
                    const varying SciVisShadingInfo &info,
                    varying vec3f &color)
{
  // Calculate AO contribution as ambient term
  if (self->aoSamples > 0 && self->aoWeight > 0.f) {
    float ao = self->aoWeight;
    if (self->aoRayLength > 0.f)
      ao *= calculateAO(self, sampleID, dg);
    // Blend AO w/ diffuse term
    color = color + info.local_opacity * info.Kd * ao;
  }
}

// Lighting functions //

inline float lightAlpha(Ray &ray, uniform Model *uniform model,
                        const float weight,
                        int remaining_depth,
                        const uniform float epsilon)
{
  float alpha = 1.f;
  const float org_t_max = ray.t;

  while (1) {
    traceRay(model,ray);

    if (ray.geomID < 0) return alpha;

    DifferentialGeometry dg;
    postIntersect(model, dg, ray, DG_MATERIALID | DG_TEXCOORD | DG_COLOR);

    uniform SciVisMaterial *scivisMaterial =
        (uniform SciVisMaterial *)dg.material;

    float material_opacity = 1.f;

    if(scivisMaterial == NULL) {
      material_opacity = dg.color.w;
    } else {
      foreach_unique( mat in scivisMaterial ) {
        material_opacity = mat->d * get1f(mat->map_d, dg.st, 1.f);
        if (mat->map_Kd) {
          vec4f Kd_from_map = get4f(mat->map_Kd,dg.st);
          material_opacity *= Kd_from_map.w;
        }
      }
    }

    alpha = alpha * (1.f - material_opacity);

    if (alpha * weight < ALPHA_THRESHOLD) return alpha;

    if (--remaining_depth <= 0)
      return 0.f;

    ray.t0 = ray.t + epsilon;
    ray.t = org_t_max;
    ray.primID = -1;
    ray.geomID = -1;
    ray.instID = -1;
  }
}

inline void shadeLights(const uniform SciVisRenderer *uniform self,
                        const varying Ray &ray,
                        const varying DifferentialGeometry &dg,
                        const varying SciVisShadingInfo &info,
                        const varying float depth,
                        varying vec3f &color)
{
  const vec3f R = ray.dir - ((2.f * dot(ray.dir, dg.Ns)) * dg.Ns);
  const vec3f P = dg.P + self->super.epsilon * dg.Ng;

  //calculate shading for all lights
  for (uniform int i = 0; self->lights && i < self->numLights; i++) {
    const uniform Light *uniform l = self->lights[i];
    const vec2f s = make_vec2f(0.5f);
    const LightSample light = l->sample(l, dg, s);

    if (reduce_max(light.radiance) > 0.f) { // any potential contribution?
      const float cosNL = abs(dot(light.direction, dg.Ns));
      const float cosLR = max(0.f, dot(light.direction, R));
      const vec3f brdf = info.Kd * cosNL + info.Ks * powf(cosLR, info.Ns);
      const vec3f light_contrib = info.local_opacity
                                  * brdf * light.radiance;

      if (self->shadowsEnabled) {
        const float max_contrib = reduce_max(light_contrib);
        if (max_contrib > .01f) {
          Ray shadowRay;
          setRay(shadowRay, P, light.direction);
          const float light_alpha = lightAlpha(shadowRay,
                                               self->super.model,
                                               max_contrib,
                                               self->maxDepth - depth,
                                               self->super.epsilon);
          color = color + light_alpha * light_contrib;
        }
      } else {
        color = color + light_contrib;
      }
    }
  }
}

// Volume shading //

inline void SciVisRenderer_computeVolumeSample(SciVisRenderer *uniform renderer,
                                               Volume *uniform volume,
                                               varying Ray &ray,
                                               varying vec4f &color)
{
  // Sample the volume at the hit point in world coordinates.
  const vec3f coordinates = ray.org + ray.t0 * ray.dir;
  const float sample = volume->computeSample(volume, coordinates);

  // Look up the color associated with the volume sample.
  vec3f sampleColor =
      volume->transferFunction->getColorForValue(volume->transferFunction,
                                                 sample);

  // Compute gradient shading, if enabled.
  if(volume->gradientShadingEnabled) {

    // Use volume gradient as the normal.
    const vec3f gradient =
        safe_normalize(volume->computeGradient(volume, coordinates));

    // Setup differential geometry for the volume sample point.
    DifferentialGeometry dg;
    dg.P = coordinates;
    dg.Ns = gradient;

    // Compute lighting.
    vec3f shadedColor = make_vec3f(0.f);
    const vec2f s = make_vec2f(0.5f);

    for (uniform uint32 i=0; i<renderer->numLights; i++) {
      const LightSample light = renderer->lights[i]->sample(renderer->lights[i], dg, s);
      const float cosNL = (gradient.x == 0.f
                           && gradient.y == 0.f
                           && gradient.z == 0.f) ?
                          1.f : abs(dot(safe_normalize(light.direction),
                                        gradient));

      shadedColor = shadedColor + sampleColor * cosNL * light.radiance;
    }

    sampleColor = shadedColor;
  }

  // Look up the opacity associated with the volume sample.
  const float sampleOpacity =
      volume->transferFunction->getOpacityForValue(volume->transferFunction,
                                                   sample);

  // Set the color contribution for this sample only (do not accumulate).
  color = clamp(sampleOpacity / volume->samplingRate)
          * make_vec4f(sampleColor.x, sampleColor.y, sampleColor.z, 1.0f);

  // Advance the ray for the next sample.
  volume->intersect(volume, ray);
}

inline
void SciVisRenderer_computeGeometrySample(SciVisRenderer *uniform self,
                                          const varying vec3i &sampleID,
                                          varying Ray &ray,
                                          varying vec4f &out_color)
{
  //NOTE(jda) - no geometry opacity handled here...

  // We compute intersections on the model and provide the contribution for the
  // closest hit.
  traceRay(self->super.model, ray);

  // No hit found.
  if(ray.geomID < 0) {
    ray.t = infinity;
    return;
  }

  // Calculate material information from DG //
  DifferentialGeometry dg;
  postIntersect(self->super.model, dg, ray,
                DG_NG|DG_NS|DG_NORMALIZE|DG_FACEFORWARD|
                DG_MATERIALID|DG_COLOR|DG_TEXCOORD);

  SciVisShadingInfo info;
  initShadingInfo(info);

  shadeMaterials(dg, info);

  info.local_opacity = info.d;

  vec3f color = make_vec3f(0.f);

  shadeAO(self, sampleID, dg, info, color);
  shadeLights(self, ray, dg, info, 0/*depth*/, color);

  out_color = make_vec4f(color.x, color.y, color.z, 1.f);
}

/*! Returns the first hit volume for the provided ray and sets the ray bounds t0 and t,
    considering the provided ray offset and any clipping. If no volume is found, the
    returned volume is NULL and ray.t0 will be set to infinity. */
inline Volume *
SciVisRenderer_intersectVolumes(uniform SciVisRenderer *uniform renderer,
                                varying Ray &ray,
                                const uniform PassInfo &passInfo,
                                const varying float &rayOffset)
{
  // The first intersected volume.
  Volume * volume = NULL;

  // The ray with bounds for the first intersected volume.
  Ray volumeRay = ray;
  volumeRay.t0 = infinity;

  // Test each volume and find the first intersection.
  for (uniform int32 i=0; i<renderer->super.model->volumeCount; i++) {
    Volume *uniform volume_i = renderer->super.model->volumes[i];

    // Intersect volume bounding box.
    float t0, t1;
    intersectBox(ray, volume_i->boundingBox, t0, t1);

    // Clip against volume clipping box (if specified).
    if(ne(volume_i->volumeClippingBox.lower, volume_i->volumeClippingBox.upper)) {
      float tClip0, tClip1;
      intersectBox(ray, volume_i->volumeClippingBox, tClip0, tClip1);

      t0 = max(t0, tClip0);
      t1 = min(t1, tClip1);
    }

    // Update intersected volume.
    if (t0 < t1 && t0 < volumeRay.t0) {
      volumeRay.t0 = t0;
      volumeRay.t = t1;
      volume = volume_i;
    }
  }

  // Update the provided ray.
  ray = volumeRay;

  // If we intersected a volume, offset ray by a fraction of the nominal ray
  // step.
  if (volume)
    ray.t0 += rayOffset * volume->samplingStep * rcpf(volume->samplingRate);

  // Return the first intersected volume.
  return volume;
}

/*! This function intersects the volume and geometries. */
void SciVisRenderer_intersect(uniform SciVisRenderer *uniform renderer,
                              varying Ray &ray,
                              const uniform PassInfo &passInfo,
                              const varying float &rayOffset,
                              const varying vec3i &sampleID,
                              varying vec4f &color,
                              varying float &depth)
{
  const region1f clipRange = passInfo.region;

  if (clipRange.lower != 0.f) {
    ray.t0 = max(ray.t0,clipRange.lower);
    ray.t = min(ray.t,clipRange.upper);
  }

  // Original tMax for ray interval
  const float tMax = ray.t;

  // Ray epsilon superd on bounding box of all volumes.
  uniform box3f boundingBox = renderer->super.model->volumeCount
    ? renderer->super.model->volumes[0]->boundingBox
    : make_box3f(make_vec3f(0.f), make_vec3f(0.f));

  Model *uniform model = renderer->super.model;
  for (uniform int32 i=1; i<renderer->super.model->volumeCount; i++) {
    boundingBox.lower = min(boundingBox.lower,
                            model->volumes[i]->boundingBox.lower);
    boundingBox.upper = max(boundingBox.upper,
                            model->volumes[i]->boundingBox.upper);
  }

  const uniform float epsilon
    = renderer->super.model->volumeCount
    ? 1e-4f * distance(boundingBox.lower, boundingBox.upper)
    : 1e-4f;

  // Copy of the ray for geometry intersection. The original ray is
  // used for volume intersection.
  Ray geometryRay = ray;
  geometryRay.primID = -1;
  geometryRay.geomID = -1;
  geometryRay.instID = -1;

  // Get first intersected volume for each ray and set the ray bounds.
  Volume *volume = SciVisRenderer_intersectVolumes(renderer, ray,
                                                   passInfo, rayOffset);

  // Provide ray offset for use with isosurface geometries (this value
  // ignored elsewhere).
  if (volume != NULL)
    geometryRay.time = -rayOffset * volume->samplingStep;

  // Separate color contributions for the volume and geometries. Initialize to
  // provided color in case of no contribution...
  vec4f volumeColor = color;
  vec4f geometryColor = color;

  // Initial trace through geometries.
  SciVisRenderer_computeGeometrySample(renderer, sampleID,
                                       geometryRay, geometryColor);

  // Depth is the first volume bounding box or geometry hit
  depth = min(ray.t0, geometryRay.t);

  // Trace the ray through the volume and geometries.
  float firstHit;

  while ((firstHit = min(ray.t0, geometryRay.t)) < min(tMax,clipRange.upper)
         && min(min(color.x, color.y), color.z) < 1.0f && color.w < 0.99f) {
    if (firstHit == ray.t0) {

      // Check to see if we've exited the current volume.
      if (ray.t0 >= ray.t) {

        ray.t0 = ray.t + epsilon;
        ray.t = tMax;
        volume = SciVisRenderer_intersectVolumes(renderer, ray,
                                                 passInfo, rayOffset);
      } else {

        if (any(volume == NULL))
          print("ACCESSING NULL VOLUME HERE!\n");

        // Compute the volume sample at the current position and advance the
        // ray.
        foreach_unique (v in volume)
          SciVisRenderer_computeVolumeSample(renderer, v, ray, volumeColor);

        // Volume contribution.
        color = color + (1.0f - color.w) * volumeColor;

      }
    } else if (firstHit == geometryRay.t) {

      // Geometry contribution.
      color = color + (1.0f - color.w) * geometryColor;

      if (color.w < 0.99f) {
        // Reset geometry ray.
        geometryRay.t0 = geometryRay.t + epsilon;
        geometryRay.t = tMax; //!< end of valid ray interval for traceRay()
        geometryRay.primID = -1;
        geometryRay.geomID = -1;
        geometryRay.instID = -1;

        // Update ray offset for use with isosurface geometries superd on current
        // volume (this value ignored elsewhere).
        geometryRay.time = volume ? -rayOffset * volume->samplingStep : 0.f;

        // Trace next geometry ray.
        SciVisRenderer_computeGeometrySample(renderer, sampleID,
                                             geometryRay, geometryColor);
      }

    }
  }
}

// Main shading function //

inline
void SciVisRenderer_shadeRay(const uniform SciVisRenderer *uniform self,
                             varying ScreenSample &sample)
{ 
  Ray &ray = sample.ray;
  // ISPC issue #703. Switch to 'nice' code once ISPC #703 is fixed.
  // print("ray.dir % % %\n",ray.dir.x,ray.dir.y,ray.dir.z);
  vec3f color = make_vec3f(0.f);
  float path_opacity = 1.f;
  int depth = 0;

  while (1) {

    traceRay(self->super.model, ray);

    // Record depth of first hit in z buffer //
    if (depth == 0) {
      sample.z = ray.t;
    }

    // Check if we missed, if so we are done //
    if (ray.geomID < 0) {
      sample.rgb = self->super.backgroundEnabled ?
                   color + path_opacity * self->super.bgColor :
                   color;
      sample.alpha = 1.f - path_opacity;
      return;
    }

    // Start shading //

    // Calculate material information from DG //
    DifferentialGeometry dg;
    postIntersect(self->super.model,
                  dg,
                  ray,
                  DG_NG|DG_NS|DG_NORMALIZE|DG_FACEFORWARD|
                  DG_MATERIALID|DG_COLOR|DG_TEXCOORD);

    SciVisShadingInfo info;
    initShadingInfo(info);

    shadeMaterials(dg, info);

    info.local_opacity = path_opacity * info.d;

    if (info.local_opacity > 0.01f) { // worth shading?
      shadeAO(self, sample.sampleID, dg, info, color);
      shadeLights(self, ray, dg, info, depth, color);
    }

    // kill path when reached max depth or if remaining contribution too low 
    path_opacity = path_opacity * (1.f - info.d);
    depth++;
    if (depth >= self->maxDepth | path_opacity < 0.01f ) {
      sample.rgb = color;
      sample.alpha = 1.f - path_opacity;
      return;
    }

    ray.t0 = ray.t + self->super.epsilon;
    ray.t = infinity;
    ray.primID = -1;
    ray.geomID = -1;
    ray.instID = -1;
  }
}

void SciVisRenderer_renderSample(uniform Renderer *uniform _self,
                                 void *uniform perFrameData,
                                 varying ScreenSample &sample)
{
  //NOTE(jda) - Eliminate #if'd out code path when satisfied with surface only
  //            scene performance and features
#if 0
  uniform SciVisRenderer *uniform self =
      (uniform SciVisRenderer *uniform)_self;
  SciVisRenderer_shadeRay(self, sample);
#else
  SciVisRenderer *uniform renderer
    = (SciVisRenderer *uniform) _self;

  PassInfo *uniform passInfo
    = (PassInfo *uniform)perFrameData;

  // Background color.
  const uniform bool useBG = ((passInfo == NULL) || passInfo->useBG);

  // Ray offset for this sample, as a fraction of the nominal step size.
  float rayOffset = precomputedHalton2(sample.sampleID.z);
  int ix = sample.sampleID.x % 4;
  int iy = sample.sampleID.y % 4;
  int patternID = ix + 4 * iy;
  rayOffset += precomputedHalton3(patternID);

  if(rayOffset > 1.f) rayOffset -= 1.f;

  // Provide the renderer to the intersector as it contains all
  // volumes, geometries, etc.
  vec4f color = make_vec4f(0.0f,0.f,0.f,0.f);
  float depth = infinity;

  if (passInfo != NULL) {
    SciVisRenderer_intersect(renderer, sample.ray, *passInfo,
                             rayOffset, sample.sampleID, color, depth);
  } else {
    uniform PassInfo dummyPassInfo;
    dummyPassInfo.region = make_region1f(0.f,inf);
    dummyPassInfo.useBG = true;
    dummyPassInfo.block = NULL;
    SciVisRenderer_intersect(renderer, sample.ray, dummyPassInfo,
                             rayOffset, sample.sampleID, color, depth);
  }

  // Attenuate the foreground and background colors by the opacity.
  if (useBG && renderer->super.backgroundEnabled) {
    const vec4f background = make_vec4f(renderer->super.bgColor, 1.f);
    color = color.w * color + (1.0f - color.w) * background;
  }

  // Store the result in the sample.
  sample.rgb.x = color.x;
  sample.rgb.y = color.y;
  sample.rgb.z = color.z;
  sample.alpha = color.w;
  sample.z = depth;
#endif
}

// Exports (called from C++)
//////////////////////////////////////////////////////////////////////////////

export void SciVisRenderer_set(void *uniform _self,
                               const uniform bool shadowsEnabled,
                               const uniform int maxDepth,
                               const uniform int aoSamples,
                               const uniform float aoRayLength,
                               const uniform float aoWeight,
                               void **uniform lights,
                               const uniform uint32 numLights)
{
  uniform SciVisRenderer *uniform self =
      (uniform SciVisRenderer *uniform)_self;

  self->shadowsEnabled = shadowsEnabled;
  self->maxDepth = maxDepth;
  self->aoSamples = aoSamples;
  self->aoRayLength = aoRayLength;
  self->aoWeight = aoWeight;
  self->lights = (const uniform Light *uniform *uniform)lights;
  self->numLights = numLights;
}

export void *uniform SciVisRenderer_create(void *uniform cppE)
{
  uniform SciVisRenderer *uniform self = uniform new uniform SciVisRenderer;
  Renderer_Constructor(&self->super,cppE);
  self->super.renderSample = SciVisRenderer_renderSample;
  SciVisRenderer_set(self, true, 10, 4, infinity, 1.f, NULL, 0);

  return self;
}