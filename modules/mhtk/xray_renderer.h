/********************************************************************* *\
 * INTEL CORPORATION PROPRIETARY INFORMATION                            
 * This software is supplied under the terms of a license agreement or  
 * nondisclosure agreement with Intel Corporation and may not be copied 
 * or disclosed except in accordance with the terms of that agreement.  
 * Copyright (C) 2014 Intel Corporation. All Rights Reserved.           
 ********************************************************************* */

#pragma once

// ospray
#include "ospray/render/renderer.h"
// embree
#include "embree2/rtcore.h"
#include "embree2/rtcore_scene.h"

namespace ospray {
  struct Camera;
  struct Model;
  struct Volume;
  
  namespace mhtk {

    // /*! \defgroup mhtk_module_xray "XRay" Test Renderer for MHTK Module 
    //   @ingroup mhtk_module
    //   @{ */

    // /*! \brief Scalar variant of the sample "XRay" renderer to test
    //     the multi-hit traversal kernel (\ref mhtk_module) */
    // struct ScalarXRayRenderer : public Renderer {
    //   virtual std::string toString() const { return "ospray::mhtk::ScalarXRayRenderer"; }
    //   virtual void renderTile(Tile &tile);
    //   virtual void commit();

    //   Camera  *camera;
    //   Model   *model;
    //   RTCScene embreeSceneHandle;
    // };

    /*! \brief Scalar variant of the sample "XRay" renderer to test
        the multi-hit traversal kernel (\ref mhtk_module) */
    struct ISPCXRayRenderer : public Renderer {
      ISPCXRayRenderer();

      virtual std::string toString() const { return "ospray::mhtk::ISPCXRayRenderer"; }
      // virtual TileRenderer::RenderJob *createRenderJob(FrameBuffer *fb);
      virtual void commit();

      Model   *model;
    };

    /*! @} */
  }
}