/*
 * ndfBinner.cc
 * Copyright (C) 2017 benjamin <benjamin@blaptop>
 *
 * Distributed under terms of the MIT license.
 */

#include "ndfBinner.h"

// ispc exports
#include "ndfBinner_ispc.h"

namespace ospray {
namespace ndf {

NDFBinner::NDFBinner() { ispcEquivalent = ispc::NDFBinner_create(this); }

void NDFBinner::commit() {
  Renderer::commit();

  const int32 seed = getParam1i("seed", 24);
  const int32 binType = getParam1i("binType", 2);
  const int32 binSize = getParam1i("binSize", 16);
  const vec4f globalToLocal =
      getParam4f("globalToLocal", vec4f(1.f, 0.f, 0.f, 0.f));
  if (getIE()) {
    ispc::NDFBinner_set(getIE(), (const ispc::vec4f&)globalToLocal, seed,
                        binType, binSize);
  }
}

void NDFBinner::resetBins() { ispc::NDFBinner_resetBins(getIE()); }

void NDFBinner::getBinned(float (&binned)[]) {
  ispc::NDFBinner_getBinned(getIE(), binned);
}

OSP_REGISTER_RENDERER(NDFBinner, ndfbinner);

}  // ::ospray::ndf
}  // ::ospray
