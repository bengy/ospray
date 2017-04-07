#pragma once
// ospray

// system
#include <vector>

namespace ospray {
namespace ndf {

/*! \brief Renderer that samples normals
*/
struct Renderer;
struct NormalSampler : public Renderer {
  NormalSampler();
  virtual ~NormalSampler() = default;
  virtual std::string toString() const override;
  virtual void commit() override;
  std::string getTest() { return "it works!"; }
};

// Inlined member functions ///////////////////////////////////////////////

inline std::string NormalSampler::toString() const {
  return "ospray::NormalSampler";
}

}  // ::ospray::scivis
}  // ::ospray
