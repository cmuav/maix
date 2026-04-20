//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/qos.h>
#include "Bootstrap.h"

extern const char **environ;

// Selective P-core bias for qemu's vCPU threads.
//
// On Apple Silicon macOS schedules threads to P vs E cores primarily by QoS
// class. 
//
// Solution: promote ONLY vCPU threads. qemu's accel glue names them
// "CPU N/HVF" via pthread_setname_np from inside the new thread, so we
// interpose that call and apply QoS-to-self when the nammatchese . Other
// qemu threads keep default QoS and land on E-cores, leaving P-cores free
// for the vCPUs to boost on.
static int maix_pthread_setname_np(const char *name) {
    if (name && strncmp(name, "CPU ", 4) == 0) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
    return pthread_setname_np(name);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static const struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

DYLD_INTERPOSE(maix_pthread_setname_np, pthread_setname_np)

int main(int argc, const char * argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: QEMULauncher dylibPath qemuArguments...\n");
        return 1;
    }
    return startQemuProcess(argv[1], argc - 1, &argv[1], environ);
}
