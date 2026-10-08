/*
 * Copyright © 2016 Red Hat.
 * Copyright © 2016 Bas Nieuwenhuizen
 *
 * based on amdgpu winsys.
 * Copyright © 2011 Marek Olšák <maraeo@gmail.com>
 * Copyright © 2015 Advanced Micro Devices, Inc.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef RADV_AMDGPU_CS_H
#define RADV_AMDGPU_CS_H

#include <assert.h>
#include <stdint.h>

#include "radv_amdgpu_winsys.h"
#include "radv_radeon_winsys.h"

enum { MAX_RINGS_PER_TYPE = 8 };

struct radv_amdgpu_fence {
   struct amdgpu_cs_fence fence;
};

/* Xclipse 920 GFX pacing, see radv_xclipse_pace_begin(). */
struct radv_xclipse_pace {
   uint32_t syncobj; /* timeline: point n is signalled by the n-th GFX job */
   uint64_t count;   /* points signalled so far */
   uint64_t seq[2];  /* kernel seq_no of points count and count - 1, indexed by point & 1 */
   uint64_t last_ns; /* time of the previous GFX submit */
   uint64_t avg_ns;  /* running mean of the submit interval while the GPU is backlogged */
};

struct radv_amdgpu_ctx {
   struct radv_amdgpu_winsys *ws;
   uint32_t ctx_handle;
   struct radv_amdgpu_fence last_submission[AMDGPU_HW_IP_NUM + 1][MAX_RINGS_PER_TYPE];

   struct radeon_winsys_bo *fence_bo;

   uint32_t queue_syncobj[AMDGPU_HW_IP_NUM + 1][MAX_RINGS_PER_TYPE];
   bool queue_syncobj_wait[AMDGPU_HW_IP_NUM + 1][MAX_RINGS_PER_TYPE];

   struct radv_xclipse_pace xclipse_pace[MAX_RINGS_PER_TYPE];
};

static inline struct radv_amdgpu_ctx *
radv_amdgpu_ctx(struct radeon_winsys_ctx *base)
{
   return (struct radv_amdgpu_ctx *)base;
}

void radv_amdgpu_cs_init_functions(struct radv_amdgpu_winsys *ws);

#endif /* RADV_AMDGPU_CS_H */
