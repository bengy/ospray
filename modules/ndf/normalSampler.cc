// obj
#include "normalSampler.h"
#include "render/Renderer.h"
// ispc exports
#include "normalSampler_ispc.h"

namespace ospray {
namespace ndf {

NormalSampler::NormalSampler() {
  ispcEquivalent = ispc::NormalSampler_create(this);
}

void NormalSampler::commit() {
  Renderer::commit();

  const int32 seed = getParam1i("seed", 24);

  ispc::NormalSampler_set(getIE(), seed);
}

OSP_REGISTER_RENDERER(NormalSampler, normalsampler);

}  // ::ospray::ndf
}  // ::ospray

extern "C" void ospray_init_module_ndf() {
  std::cout << "#osp:pkd: loading 'ndf' module" << std::endl;
}
