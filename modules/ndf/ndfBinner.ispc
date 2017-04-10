
#include "fb/FrameBuffer.ih"
#include "render/util.ih"
#include "common/Model.ih"
#include "texture/Texture2D.ih"
#include "lights/Light.ih"
#include "render/Renderer.ih"
#include "math/random.ih"
#include "math/sampling.ih"
#include "math/LinearSpace.ih"
#include "math/vec.ih"
#include "camera/Camera.ih"

#define ALPHA_THRESHOLD (.05f)

// Data types /////////////////////////////////////////////////////////////////

struct NDFBinner {
  Renderer super;
  float volumeEpsilon;
  vec4f globalToLocal;
  uint32 seed;
  uint32 sampleCount;
  uint32 binType;
  uint32 binSize;
  uint32 *binned;
};

// Function definitions ///////////////////////////////////////////////////////
uniform uint32 maximumValueOffset(uniform uint32 a[], uint32 n) {
  uint32 maxValueIndex = 0;
  uint32 maxValue = a[0];
  for (uint32 i = programIndex + 1; i < n; i += programCount) {
    if (a[i] > maxValue) {
      maxValue = a[i];
      maxValueIndex = i;
    }
  }

  // Now loop over the individual winners from each program instance and
  // pick the index for the true minimum.
  uniform uint32 maxValueIndexU = extract(maxValueIndex, 0);
  uniform uint32 maxValueU = extract(maxValue, 0);
  for (uniform uint32 i = 1; i < programCount; ++i) {
    if (extract(maxValue, i) < maxValueU) {
      maxValueU = extract(maxValue, i);
      maxValueIndexU = extract(maxValueIndex, i);
    }
  }
  return maxValueIndexU;
}

export void NDFBinner_resetBins(void *uniform _self) {
  uniform NDFBinner *uniform self = (uniform NDFBinner *uniform)_self;
  for(uint32 i = 0; i< self->binSize * self->binSize; ++i) {
    self->binned[i] = 0;
  }
}

export void NDFBinner_getBinned(void *uniform _self, uniform float (&binned)[]) {
  uniform NDFBinner *uniform self = (uniform NDFBinner *uniform)_self;
  uint32 binCount = self->binSize * self->binSize;
  int maxIndex = maximumValueOffset(self->binned, binCount);
  for(int i = 0; i < binCount; ++i) {
    binned[i] = ((float)self->binned[i]) / self->binned[maxIndex];
  }
}

inline
vec3f NDFBinner_computeGeometrySample(NDFBinner *uniform self,
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
void NDFBinner_intersect(uniform NDFBinner *uniform renderer,
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

  normal = NDFBinner_computeGeometrySample(renderer,
      sampleID, geometryRay);
  depth = geometryRay.t;
}

inline uint32 NDFBinner_getIndex(uniform NDFBinner *uniform self, const vec2f uv) {
  uint32 indexX = min(self->binSize - 1, (uint32)floor(uv.x * self->binSize));
  uint32 indexY = min(self->binSize - 1, (uint32)floor(uv.y * self->binSize));
  return indexX + indexY * self->binSize;
}

inline vec2f NDFBinner_projectNormalProjection(const vec3f normal) {
  // Simply discard z as it can be recovered due to sqrt(x^2 + y^2 + z^2) = 1
  return make_vec2f(normal.x / 2.f + 0.5f, normal.y / 2.f + 0.5f);
}

inline vec2f NDFBinner_projectSpherical(const vec3f normal) {
  float theta = atan2(normal.y, normal.x);
  if (theta < 0) {
    theta += 2.f * PI;
  }
  float phi = acos(normal.z);
  return make_vec2f(theta / (2.f * PI), phi / (2.f * PI));
}

inline vec2f NDFBinner_projectLambert(const vec3f normal) {
  // Map from using the lambert azimuthal equation. Equator is mapped to circle
  // of radius sqrt(2) around (0, 0)
  float x = (sqrt(2.f / (1.f + normal.z)) * normal.x + sqrt(2.f)) / (2.f * sqrt(2.f));
  float y = (sqrt(2.f / (1.f + normal.z)) * normal.y + sqrt(2.f)) / (2.f * sqrt(2.f));
  return make_vec2f(x, y);
}

inline vec3f rotate(const vec3f v, const vec4f quat) {
  vec3f u = make_vec3f(quat.x, quat.y, quat.z);
  float s = quat.w;
  return 2.f * dot(u, v) * u + (s * s - dot(u, u)) * v + 2.f * s * cross(u, v);
}

void NDFBinner_renderSample(uniform Renderer *uniform _self,
                                 void *uniform perFrameData,
                                 varying ScreenSample &sample) {

  NDFBinner *uniform self
    = (NDFBinner *uniform) _self;

  uniform FrameBuffer *uniform fb = self->super.fb;
  uniform Camera *uniform camera = self->super.camera;

  // init RNG
  uint32 id = fb->size.x*sample.sampleID.y+sample.sampleID.x;
  RandomTEA rng_state; varying RandomTEA* const uniform rng = &rng_state;
  RandomTEA__Constructor(rng, id, self->seed);
  CameraSample cameraSample;
  const int spp = self->super.spp;
  for(uint32 s = 0; s < spp; ++s) {
    const vec2f pixelSample = RandomTEA__getFloats(rng);
    cameraSample.screen.x = (sample.sampleID.x + pixelSample.x) * fb->rcpSize.x;
    cameraSample.screen.y = (sample.sampleID.y + pixelSample.y) * fb->rcpSize.y;
    camera->initRay(camera, sample.ray, cameraSample);

    // Provide the renderer to the intersector as it contains all
    // volumes, geometries, etc.
    vec3f normal = make_vec3f(0.0f);
    float depth = infinity;

    NDFBinner_intersect(self, sample.ray,
                             sample.sampleID, normal, depth);
    float sum = abs(normal.x) + abs(normal.y) + abs(normal.z);
    if(sum > 0.5f) {
      vec3f n = rotate(normal, self->globalToLocal);
      vec2f uv;
      if(self->binType == 0) {
        uv = NDFBinner_projectNormalProjection(n);
      } else if(self->binType == 1) {
        uv = NDFBinner_projectSpherical(n);
      } else {
        uv = NDFBinner_projectLambert(n);
      }
      uint32 index = NDFBinner_getIndex(self, uv);
      atomic_add_global(&self->binned[index], 1);
    }
    sample.rgb.x += normal.x;
    sample.rgb.y += normal.y;
    sample.rgb.z += normal.z;
    if(sum > 0.5) {
      sample.alpha += 1.f;
      sample.z = depth;
    }
    sample.rgb = sample.rgb / spp;
    sample.alpha = sample.alpha / spp;
    sample.z = sample.z / spp;
  }
  // Store the result in the sample.
}


// Exports (called from C++)
//////////////////////////////////////////////////////////////////////////////
export void NDFBinner_set(void *uniform _self,
                          const uniform vec4f& globalToLocal,
                          const uniform int32 seed,
                          const uniform int32 binType,
                          const uniform int32 binSize) {
  uniform NDFBinner *uniform self = (uniform NDFBinner *uniform)_self;
  uniform uint32 binCount = binSize * binSize;
  self->globalToLocal = globalToLocal;
  self->binType = (uint32) binType;
  if(self->binSize != binSize) {
    if(self->binned != NULL) {
      // TODO delete array
      delete[] self->binned;
    }
    self->binned = uniform new uint32[binCount];
  }
  self->binSize = (uint32) binSize;
  self->seed = (uint32) seed;
}

export void *uniform NDFBinner_create(void *uniform cppE) {
  uniform NDFBinner *uniform self = uniform new uniform NDFBinner;
  Renderer_Constructor(&self->super,cppE, NULL, NULL, 1);
  uniform vec4f identityRot = make_vec4f(1.f, 0.f, 0.f, 0.f);
  NDFBinner_set(self, identityRot, 24, 2, 16);
  return self;
}
