/* engine/bridge/tests/bridge_smoke_test.c
 *
 * Deliberately a .c file, not .cpp: proves bw_bridge.h's extern "C" API is
 * actually callable from plain C, which is what dart:ffi and the eventual
 * WASM/JS glue will be binding against — not just C++ compiling under an
 * extern "C" block.
 *
 * Usage: bridge_smoke_test [data_dir] [map_file]
 */

#include "bw_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void build_default_paths(char* data_dir, size_t data_dir_sz,
                                  char* map_file, size_t map_file_sz) {
	const char* home = getenv("HOME");
	if (!home) home = "";
	snprintf(data_dir, data_dir_sz, "%s/box/media/games/BROOD/", home);
	snprintf(map_file, map_file_sz, "%smaps/ladder/(4)Lost Temple.scm", data_dir);
}

int main(int argc, char** argv) {
	char default_data_dir[1024];
	char default_map_file[1024];
	build_default_paths(default_data_dir, sizeof(default_data_dir),
	                     default_map_file, sizeof(default_map_file));

	const char* data_dir = argc > 1 ? argv[1] : default_data_dir;
	const char* map_file = argc > 2 ? argv[2] : default_map_file;

	printf("bridge_smoke_test: abi_version=%d\n", bw_bridge_abi_version());

	bw_bridge_t* bridge = bw_bridge_create();
	if (!bridge) {
		printf("bridge_smoke_test: FAIL — bw_bridge_create returned NULL\n");
		return 1;
	}

	bw_status st = bw_bridge_load_assets(bridge, data_dir);
	if (st != BW_OK) {
		printf("bridge_smoke_test: FAIL — bw_bridge_load_assets status=%d (data_dir='%s')\n", st, data_dir);
		bw_bridge_destroy(bridge);
		return 1;
	}

	const int my_slot = 0;
	const int my_race_terran = 1;
	st = bw_bridge_new_melee_game(bridge, map_file, my_slot, my_race_terran);
	if (st != BW_OK) {
		printf("bridge_smoke_test: FAIL — bw_bridge_new_melee_game status=%d (map_file='%s')\n", st, map_file);
		bw_bridge_destroy(bridge);
		return 1;
	}

	int units0 = bw_bridge_unit_count(bridge, my_slot);
	int minerals0 = bw_bridge_minerals(bridge, my_slot);
	int gas0 = bw_bridge_gas(bridge, my_slot);
	printf("bridge_smoke_test: initial units=%d minerals=%d gas=%d\n", units0, minerals0, gas0);

	st = bw_bridge_step(bridge, 500);
	if (st != BW_OK) {
		printf("bridge_smoke_test: FAIL — bw_bridge_step status=%d\n", st);
		bw_bridge_destroy(bridge);
		return 1;
	}

	int frame = bw_bridge_current_frame(bridge);
	int units1 = bw_bridge_unit_count(bridge, my_slot);
	int minerals1 = bw_bridge_minerals(bridge, my_slot);
	printf("bridge_smoke_test: after step frame=%d units=%d minerals=%d\n", frame, units1, minerals1);

	/* Rendering parts-list check: grab one visible sprite, decode its frame
	 * to indexed pixels, apply the palette (+ player-color remap), and dump
	 * it as a .ppm so a human can look at it and confirm it's really a
	 * recognizable sprite, not noise. */
	bw_sprite_info sprites[4096];
	int sprite_count = bw_bridge_get_visible_sprites(bridge, sprites, 4096);
	printf("bridge_smoke_test: visible sprites=%d\n", sprite_count);

	if (sprite_count > 0) {
		uint8_t palette[1024];
		uint8_t player_colors[128];
		if (bw_bridge_get_palette(bridge, palette, sizeof(palette)) != BW_OK) {
			printf("bridge_smoke_test: FAIL — bw_bridge_get_palette\n");
			bw_bridge_destroy(bridge);
			return 1;
		}
		if (bw_bridge_get_player_colors(bridge, player_colors, sizeof(player_colors)) != BW_OK) {
			printf("bridge_smoke_test: FAIL — bw_bridge_get_player_colors\n");
			bw_bridge_destroy(bridge);
			return 1;
		}

		const bw_sprite_info* s = &sprites[0];
		int w, h;
		if (bw_bridge_get_image_frame_size(bridge, s->image_type_id, s->frame_index, &w, &h) != BW_OK) {
			printf("bridge_smoke_test: FAIL — bw_bridge_get_image_frame_size\n");
			bw_bridge_destroy(bridge);
			return 1;
		}
		printf("bridge_smoke_test: decoding image_type_id=%d frame=%d owner=%d size=%dx%d\n",
		       s->image_type_id, s->frame_index, s->owner, w, h);

		uint8_t* indexed = (uint8_t*)malloc((size_t)w * (size_t)h);
		if (bw_bridge_decode_image_frame(bridge, s->image_type_id, s->frame_index, s->flipped, indexed, w * h) != BW_OK) {
			printf("bridge_smoke_test: FAIL — bw_bridge_decode_image_frame\n");
			free(indexed);
			bw_bridge_destroy(bridge);
			return 1;
		}

		const uint8_t* colors = &player_colors[s->owner * 8];
		FILE* f = fopen("sprite_decode_test.ppm", "wb");
		if (f) {
			fprintf(f, "P6\n%d %d\n255\n", w, h);
			for (int i = 0; i != w * h; ++i) {
				uint8_t idx = indexed[i];
				if (idx >= 8 && idx < 16) idx = colors[idx - 8];
				uint8_t rgb[3] = {palette[idx * 4 + 0], palette[idx * 4 + 1], palette[idx * 4 + 2]};
				fwrite(rgb, 1, 3, f);
			}
			fclose(f);
			printf("bridge_smoke_test: wrote sprite_decode_test.ppm\n");
		}
		free(indexed);
	}

	bw_bridge_destroy(bridge);

	if (frame != 500) {
		printf("bridge_smoke_test: FAIL — expected frame=500, got %d\n", frame);
		return 1;
	}
	if (units1 <= 0) {
		printf("bridge_smoke_test: FAIL — no units after stepping\n");
		return 1;
	}

	printf("bridge_smoke_test: OK\n");
	return 0;
}
