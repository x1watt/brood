// engine/bridge/src/bw_render_util.h
//
// Small, SDL-free pieces lifted from OpenBW's reference renderer
// (engine/vendor/openbw/ui/ui.h) so the bridge can decode GRP sprite frames
// and load the handful of palette/recolor files it needs, without pulling in
// ui.h's full SDL-coupled window/drawing stack (native_window.h etc).
//
// draw_frame() below is OpenBW's own BW-format RLE unpacker, copied
// verbatim (it has no SDL dependency in the original either) — this project
// does not reimplement that format. load_pcx_data() is likewise copied
// as-is. Everything else here is new glue code.
//
// Deliberately NOT included: ui.h's draw_image()/draw_tile() (the full
// per-modifier compositor and tile/terrain renderer) — those stay
// unreused. This project only needs "decode one sprite frame to indexed
// pixels"; compositing (player-color tint, cloak, z-order, terrain) happens
// in Flutter so sprites can later be swapped for custom HD textures. See
// docs/architecture.md.

#ifndef BW_RENDER_UTIL_H
#define BW_RENDER_UTIL_H

#include "bwgame.h"

#include <array>
#include <cstring>

namespace bwgame {
namespace bw_render_util {

// --- copied from ui/ui.h: load_pcx_data() ----------------------------------

struct pcx_image {
	size_t width;
	size_t height;
	a_vector<uint8_t> data;
};

template<typename data_T>
pcx_image load_pcx_data(const data_T& data) {
	data_loading::data_reader_le r(data.data(), data.data() + data.size());
	auto base_r = r;
	auto id = r.get<uint8_t>();
	if (id != 0x0a) error("pcx: invalid identifier %#x", id);
	r.get<uint8_t>(); // version
	auto encoding = r.get<uint8_t>();
	auto bpp = r.get<uint8_t>();
	auto offset_x = r.get<uint16_t>();
	auto offset_y = r.get<uint16_t>();
	auto last_x = r.get<uint16_t>();
	auto last_y = r.get<uint16_t>();

	if (encoding != 1) error("pcx: invalid encoding %#x", encoding);
	if (bpp != 8) error("pcx: bpp is %d, expected 8", bpp);
	if (offset_x != 0 || offset_y != 0) error("pcx: offset %d %d, expected 0 0", offset_x, offset_y);

	r.skip(2 + 2 + 48 + 1);

	auto bit_planes = r.get<uint8_t>();
	auto bytes_per_line = r.get<uint16_t>();

	size_t width = last_x + 1;
	size_t height = last_y + 1;

	pcx_image pcx;
	pcx.width = width;
	pcx.height = height;
	pcx.data.resize(width * height);

	r = base_r;
	r.skip(128);

	auto padding = bytes_per_line * bit_planes - width;
	if (padding != 0) error("pcx: padding not supported");

	uint8_t* dst = pcx.data.data();
	uint8_t* dst_end = pcx.data.data() + pcx.data.size();

	while (dst != dst_end) {
		auto v = r.get<uint8_t>();
		if ((v & 0xc0) == 0xc0) {
			v &= 0x3f;
			auto c = r.get<uint8_t>();
			for (; v; --v) {
				if (dst == dst_end) error("pcx: failed to decode");
				*dst++ = c;
			}
		} else {
			*dst = v;
			++dst;
		}
	}

	return pcx;
}

// --- copied from ui/ui.h: the GRP frame RLE unpacker ------------------------

struct no_remap {
	uint8_t operator()(uint8_t new_value, uint8_t old_value) const {
		return new_value;
	}
};

template<bool bounds_check, bool flipped, typename remap_F>
void draw_frame(const grp_t::frame_t& frame, uint8_t* dst, size_t pitch, size_t offset_x, size_t offset_y, size_t width, size_t height, remap_F&& remap_f) {
	for (size_t y = 0; y != offset_y; ++y) dst += pitch;

	for (size_t y = offset_y; y != height; ++y) {
		if (flipped) dst += frame.size.x - 1;

		const uint8_t* d = frame.data_container.data() + frame.line_data_offset.at(y);
		for (size_t x = flipped ? frame.size.x - 1 : 0; x != (flipped ? (size_t)0 - 1 : frame.size.x);) {
			int v = *d++;
			if (v & 0x80) {
				v &= 0x7f;
				x += flipped ? -v : v;
				dst += flipped ? -v : v;
			} else if (v & 0x40) {
				v &= 0x3f;
				int c = *d++;
				for (; v; --v) {
					if (!bounds_check || (x >= offset_x && x < width)) *dst = remap_f((uint8_t)c, *dst);
					dst += flipped ? -1 : 1;
					x += flipped ? -1 : 1;
				}
			} else {
				for (; v; --v) {
					int c = *d++;
					if (!bounds_check || (x >= offset_x && x < width)) *dst = remap_f((uint8_t)c, *dst);
					dst += flipped ? -1 : 1;
					x += flipped ? -1 : 1;
				}
			}
		}

		if (!flipped) dst -= frame.size.x;
		else ++dst;
		dst += pitch;
	}
}

// width/height here are always frame.size.x/frame.size.y for our purposes
// (the bridge always decodes a whole frame into an exactly-sized buffer; the
// cropped/scrolled variants in ui.h's version existed for screen-space
// blitting, which we don't do here).
template<typename remap_F = no_remap>
void draw_frame(const grp_t::frame_t& frame, bool flipped, uint8_t* dst, remap_F&& remap_f = remap_F()) {
	// Tightly packed output buffer: each row is exactly frame.size.x bytes,
	// so the row-to-row stride ("pitch" in the original) equals frame.size.x.
	size_t pitch = frame.size.x;
	if (flipped) draw_frame<false, true>(frame, dst, pitch, 0, 0, frame.size.x, frame.size.y, std::forward<remap_F>(remap_f));
	else draw_frame<false, false>(frame, dst, pitch, 0, 0, frame.size.x, frame.size.y, std::forward<remap_F>(remap_f));
}

// --- new glue: the handful of palette/recolor files the bridge needs -------

inline std::array<const char*, 8> tileset_names() {
	return {"badlands", "platform", "install", "AshWorld", "Jungle", "Desert", "Ice", "Twilight"};
}

// 256 RGBA8888 entries, straight from Tileset/<name>.wpe.
template<typename load_data_file_F>
a_vector<uint8_t> load_tileset_palette(size_t tileset_index, load_data_file_F&& load_data_file) {
	a_vector<uint8_t> wpe;
	load_data_file(wpe, format("Tileset/%s.wpe", tileset_names().at(tileset_index)));
	if (wpe.size() != 256 * 4) error("wpe size invalid (%d)", (int)wpe.size());
	return wpe;
}

// 16 players x 8 shades each, indices into the palette above — this is how a
// unit's "generic" palette indices (8..15) get remapped to its owner's color.
template<typename load_data_file_F>
std::array<std::array<uint8_t, 8>, 16> load_player_unit_colors(load_data_file_F&& load_data_file) {
	a_vector<uint8_t> tmp;
	load_data_file(tmp, "game/tunit.pcx");
	pcx_image tunit_pcx = load_pcx_data(tmp);
	if (tunit_pcx.width != 128 || tunit_pcx.height != 1) {
		error("tunit.pcx dimensions are %dx%d (128x1 required)", (int)tunit_pcx.width, (int)tunit_pcx.height);
	}
	std::array<std::array<uint8_t, 8>, 16> colors{};
	for (size_t i = 0; i != 16; ++i) {
		for (size_t i2 = 0; i2 != 8; ++i2) colors[i][i2] = tunit_pcx.data[i * 8 + i2];
	}
	return colors;
}

// --- new glue: terrain (megatile) decoding ----------------------------------
//
// Not reusing ui.h's load_tileset_image_data() here — that also loads creep
// rendering, cloak/warp light_pcx effects, etc, which aren't needed yet.
// Just the two files that describe what a megatile looks like.

struct tileset_terrain {
	a_vector<uint8_t> vr4;   // count * 64 bytes: 8 rows x 8 palette-index bytes per 8x8 block
	a_vector<uint16_t> vx4;  // count * 16 entries: 4x4 grid of (vr4_index<<1 | inverted) per megatile
};

template<typename load_data_file_F>
tileset_terrain load_tileset_terrain(size_t tileset_index, load_data_file_F&& load_data_file) {
	tileset_terrain t;
	const char* name = tileset_names().at(tileset_index);

	a_vector<uint8_t> vr4_data;
	load_data_file(vr4_data, format("Tileset/%s.vr4", name));
	t.vr4 = std::move(vr4_data); // already exactly count*64 raw bytes, no repacking needed

	a_vector<uint8_t> vx4_data;
	load_data_file(vx4_data, format("Tileset/%s.vx4", name));
	t.vx4.resize(vx4_data.size() / 2);
	for (size_t i = 0; i != t.vx4.size(); ++i) {
		t.vx4[i] = (uint16_t)(vx4_data[i * 2] | (vx4_data[i * 2 + 1] << 8));
	}
	return t;
}

// Decodes one 32x32 megatile into out (must hold 32*32 = 1024 bytes),
// palette-index pixels, same convention as draw_frame (index 0 = BW's
// transparent/background index; terrain practically never uses it, but
// nothing here assumes otherwise).
inline void decode_megatile(const tileset_terrain& t, size_t megatile_index, uint8_t* out) {
	if (megatile_index >= t.vx4.size() / 16) {
		std::memset(out, 0, 32 * 32);
		return;
	}
	const uint16_t* images = &t.vx4[megatile_index * 16];
	for (size_t by = 0; by != 4; ++by) {
		for (size_t bx = 0; bx != 4; ++bx) {
			uint16_t image_index = images[by * 4 + bx];
			bool inverted = (image_index & 1) != 0;
			size_t vr4_index = image_index >> 1;
			if (vr4_index >= t.vr4.size() / 64) continue;
			const uint8_t* block = &t.vr4[vr4_index * 64];
			for (size_t row = 0; row != 8; ++row) {
				const uint8_t* src_row = block + row * 8;
				uint8_t* dst_row = out + (by * 8 + row) * 32 + bx * 8;
				if (inverted) {
					for (size_t c = 0; c != 8; ++c) dst_row[c] = src_row[7 - c];
				} else {
					for (size_t c = 0; c != 8; ++c) dst_row[c] = src_row[c];
				}
			}
		}
	}
}

} // namespace bw_render_util
} // namespace bwgame

#endif // BW_RENDER_UTIL_H
