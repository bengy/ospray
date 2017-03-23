
#include "fb/FrameBuffer.ih"
#include "render/util.ih"
#include "common/Model.ih"
#include "texture/Texture2D.ih"
#include "lights/Light.ih"
#include "render/Renderer.ih"
#include "math/random.ih"
#include "math/sampling.ih"
#include "math/LinearSpace.ih"
#include "camera/Camera.ih"

#define ALPHA_THRESHOLD (.05f)

// Data types /////////////////////////////////////////////////////////////////

struct NormalSampler {
  Renderer super;
  float volumeEpsilon;
  uint32 seed;
};

// Function definitions ///////////////////////////////////////////////////////


inline
vec3f NormalSampler_computeGeometrySample(NormalSampler *uniform self,
                                          const varying vec3i &sampleID,
                                          varying Ray &ray) {
  traceRay(self->super.model, ray);
  // Check if we missed, if so we are done //
  if (ray.geomID < 0) {
    return make_vec3f(0.f, 0.f, 0.f);
  }
  // Calculate material information from DG //
  DifferentialGeometry dg;
  postIntersect(self->super.model,
                dg,
                ray,
                DG_NG|DG_NS|DG_NORMALIZE|DG_FACEFORWARD|DG_TANGENTS|
                DG_MATERIALID|DG_COLOR|DG_TEXCOORD);
  return dg.Ng;
}

/*! This function intersects the geometries. */
void NormalSampler_intersect(uniform NormalSampler *uniform renderer,
                              varying Ray &ray,
                              const varying vec3i &sampleID,
                              varying vec3f &normal,
                              varying float &depth) {
  // Original tMax for ray interval
  const float tMax = ray.t;

  // Copy of the ray for geometry intersection. The original ray is
  // used for volume intersection.
  Ray geometryRay = ray;
  geometryRay.primID = -1;
  geometryRay.geomID = -1;
  geometryRay.instID = -1;

  normal = NormalSampler_computeGeometrySample(renderer,
      sampleID, geometryRay);
  depth = geometryRay.t;
}

void NormalSampler_renderSample(uniform Renderer *uniform _self,
                                 void *uniform perFrameData,
                                 varying ScreenSample &sample) {

  NormalSampler *uniform self
    = (NormalSampler *uniform) _self;

  uniform FrameBuffer *uniform fb = self->super.fb;
  uniform Camera *uniform camera = self->super.camera;

  // init RNG
  uint32 id = fb->size.x*sample.sampleID.y+sample.sampleID.x;
  RandomTEA rng_state; varying RandomTEA* const uniform rng = &rng_state;
  RandomTEA__Constructor(rng, id, self->seed);
    CameraSample cameraSample;
    const vec2f pixelSample = RandomTEA__getFloats(rng);
    cameraSample.screen.x = (sample.sampleID.x + pixelSample.x) * fb->rcpSize.x;
    cameraSample.screen.y = (sample.sampleID.y + pixelSample.y) * fb->rcpSize.y;
    camera->initRay(camera, sample.ray, cameraSample);

  // Provide the renderer to the intersector as it contains all
  // volumes, geometries, etc.
  vec3f normal = make_vec3f(0.0f);
  float depth = infinity;

  NormalSampler_intersect(self, sample.ray,
                           sample.sampleID, normal, depth);

  // Store the result in the sample.
  sample.rgb.x = normal.x;
  sample.rgb.y = normal.y;
  sample.rgb.z = normal.z;
  sample.alpha = 1.f;
  sample.z = depth;
}


// Exports (called from C++)
//////////////////////////////////////////////////////////////////////////////

export void NormalSampler_set(void *uniform _self, 
                           const uniform int32 seed) {
  uniform NormalSampler *uniform self = (uniform NormalSampler *uniform)_self;
  self->seed = (uint32) seed;
}

export void *uniform NormalSampler_create(void *uniform cppE) {
  uniform NormalSampler *uniform self = uniform new uniform NormalSampler;
  Renderer_Constructor(&self->super,cppE, NULL, NULL, 1);
  self->super.renderSample = NormalSampler_renderSample;
  NormalSampler_set(self, 24);
  return self;
}
