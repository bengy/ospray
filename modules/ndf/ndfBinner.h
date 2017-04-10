/*
 * ndfBinner.h
 * Copyright (C) 2017 benjamin <benjamin@blaptop>
 *
 * Distributed under terms of the MIT license.
 */

#pragma once
// ospray
#include "normalSampler.h"

// system
#include <vector>

namespace ospray {
namespace ndf {

/*! \brief Renderer that samples normals
*/
struct NDFBinner : public NormalSampler {
  NDFBinner();
  virtual ~NDFBinner() = default;
  virtual std::string toString() const override;
  virtual void commit() override;
  void resetBins();
  void getBinned(float (&bins)[]);
  std::string getTest() { return "it works!"; }
};

// Inlined member functions ///////////////////////////////////////////////

inline std::string NDFBinner::toString() const { return "ospray::NDFBinner"; }

}  // ::ospray::ndf
}  // ::ospray
