// SPDX-License-Identifier: MIT
// Minimal stand-in for openxr-gaze-bridge: publishes a fixed gaze at 250 Hz.
// Killing it with SIGKILL leaves the file as a crashed bridge would.
#include "../../shared/gaze_shm.h"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

int main(int argc, char** argv) {
  if (argc < 6) { std::fprintf(stderr, "Usage: gaze-writer FILE UL VL UR VR [invalid]\n"); return 2; }
  int fd = open(argv[1], O_RDWR | O_CREAT, 0600);
  if (fd < 0 || ftruncate(fd, sizeof(gaze_bridge::SharedGaze))) { std::perror("output"); return 1; }
  void* mapped = mmap(nullptr, sizeof(gaze_bridge::SharedGaze), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (mapped == MAP_FAILED) { std::perror("mmap"); return 1; }
  gaze_bridge::Sample sample;
  sample.valid = argc < 7;
  sample.u[0] = std::atof(argv[2]); sample.v[0] = std::atof(argv[3]);
  sample.u[1] = std::atof(argv[4]); sample.v[1] = std::atof(argv[5]);
  for (;;) {
    gaze_bridge::publish(static_cast<gaze_bridge::SharedGaze*>(mapped), sample);
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
}
