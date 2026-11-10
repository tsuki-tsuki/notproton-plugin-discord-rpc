#pragma once
#include <stdbool.h>

void activity_init(const char *host_path);
void activity_tick(double now, bool game_connected, int (*connect_socket)(void));
void activity_clear(void);
