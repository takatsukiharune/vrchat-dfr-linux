// SPDX-License-Identifier: MIT
#include "dxvk_gaze_filter.h"
#include <cassert>
#include <cstdio>

using namespace dxvk;

int main() {
  // Side-by-side stereo viewports use half the framebuffer width. DXVK sets negative height for D3D11.
  const GazeViewportRect leftEye{0.0f, 3880.0f, 3528.0f, -3880.0f};
  const GazeViewportRect rightEye{3528.0f, 3880.0f, 3528.0f, -3880.0f};
  const GazeViewportRect fullSbs{0.0f, 3880.0f, 7056.0f, -3880.0f};
  const GazeViewportRect tinyStrip{0.0f, 100.0f, 3528.0f, -100.0f};
  const GazeViewportRect oddHalf{0.0f, 1000.0f, 800.0f, -1000.0f};
  const GazeViewportRect full2d{0.0f, 1024.0f, 2048.0f, -1024.0f};
  const GazeViewportRect mirror{0.0f, 2048.0f, 2048.0f, -2048.0f};

  assert(isStereoDrawViewport(7056, 3880, 1, &leftEye, 1));
  assert(isStereoDrawViewport(7056, 3880, 1, &rightEye, 1));
  assert(!isStereoDrawViewport(7056, 3880, 1, &fullSbs, 1));
  assert(!isStereoDrawViewport(7056, 3880, 1, &tinyStrip, 1));
  assert(!isStereoDrawViewport(2048, 1024, 1, &full2d, 1));
  assert(!isStereoDrawViewport(2048, 2048, 1, &mirror, 1));
  // Tall side-by-side targets with aspect ratio 1.6 still match when the viewport is half-width.
  assert(isStereoDrawViewport(1600, 1000, 1, &oddHalf, 1));

  // Two-layer array targets use the full eye width starting at x equal to 0.
  const GazeViewportRect arrayEye{0.0f, 2048.0f, 2048.0f, -2048.0f};
  assert(isStereoDrawViewport(2048, 2048, 2, &arrayEye, 1));
  assert(!isStereoDrawViewport(2048, 2048, 2, &oddHalf, 1));
  assert(!isStereoDrawViewport(2048, 2048, 3, &arrayEye, 1));
  assert(!isStereoDrawViewport(7056, 3880, 1, nullptr, 0));

  // The depth check rejects 2D overlays and fullscreen quads that disable depth test and write.
  assert(isStereoDraw(7056, 3880, 1, &leftEye, 1, true, true, true));
  assert(isStereoDraw(7056, 3880, 1, &leftEye, 1, true, false, true));
  assert(!isStereoDraw(7056, 3880, 1, &leftEye, 1, false, false, true));
  assert(isStereoDraw(7056, 3880, 1, &leftEye, 1, false, false, false));

  // Promotion requires 3 matching passes, and 2000 milliseconds without a match clears the entry.
  GazePassTracker tracker;
  using ms = std::chrono::milliseconds;
  const auto t0 = GazePassTracker::Clock::now();
  const GazePassKey scene{7056, 3880, 1, 97, 1, true};
  const GazePassKey post{7056, 3880, 1, 97, 1, false};
  const GazePassKey glitch{2048, 1024, 1, 43, 1, true};

  assert(tracker.status(scene, t0) == GazePassTracker::Status::Unseen);
  assert(!tracker.isConfirmed(scene, t0));

  // A single matching pass stays in Observing and expires after 2000 milliseconds.
  assert(tracker.observeMatch(glitch, t0) == GazePassTracker::Status::Observing);
  assert(tracker.status(glitch, t0 + ms(100)) == GazePassTracker::Status::Observing);
  assert(tracker.status(glitch, t0 + ms(2000)) == GazePassTracker::Status::Unseen);

  // The scene pass promotes on the third matching pass while the depthless pass key stays separate.
  assert(tracker.observeMatch(scene, t0) == GazePassTracker::Status::Observing);
  assert(tracker.observeMatch(scene, t0 + ms(11)) == GazePassTracker::Status::Observing);
  assert(tracker.observeMatch(scene, t0 + ms(22)) == GazePassTracker::Status::Confirmed);
  assert(tracker.isConfirmed(scene, t0 + ms(22)));
  assert(!tracker.isConfirmed(post, t0 + ms(22)));

  // Matching passes refresh the expiry timer, and 2000 idle milliseconds return the entry to Unseen.
  assert(tracker.observeMatch(scene, t0 + ms(1500)) == GazePassTracker::Status::Confirmed);
  assert(tracker.isConfirmed(scene, t0 + ms(3400)));
  assert(tracker.status(scene, t0 + ms(3500)) == GazePassTracker::Status::Unseen);
  // After expiry, the shape needs 3 matching passes to promote again.
  assert(tracker.observeMatch(scene, t0 + ms(3500)) == GazePassTracker::Status::Observing);

  // Unconfirmed shapes must not evict a confirmed scene pass when the table is full.
  tracker.clear();
  for (uint32_t i = 0; i < 3; ++i)
    tracker.observeMatch(scene, t0 + ms(i * 10));
  assert(tracker.isConfirmed(scene, t0 + ms(30)));
  for (uint32_t i = 0; i < 64; ++i) {
    GazePassKey noise{1000 + i * 2, 1000, 1, 97, 1, true};
    assert(tracker.observeMatch(noise, t0 + ms(40 + i)) == GazePassTracker::Status::Observing);
  }
  assert(tracker.isConfirmed(scene, t0 + ms(200)));

  tracker.clear();
  assert(tracker.status(scene, t0 + ms(200)) == GazePassTracker::Status::Unseen);

  std::puts("Gaze filter tests passed");
  return 0;
}
