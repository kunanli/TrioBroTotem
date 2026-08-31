shader_type spatial;

// 角色描邊（TD-09 指定的做法：inverted hull）。
//
// 為什麼是 inverted hull 而不是螢幕空間的邊緣偵測：本作之後要做分屏，
// 螢幕空間的做法在兩個視口下要跑兩次；inverted hull 是幾何的一部分，
// 對分屏天然免費（docs/13 TD-09）。
//
// 這支 shader 的任務來自 docs/09 的美術方向第一條：
// 「剪影必須從遠處就能分辨」，以及「半畫面尺寸下仍須可辨識」。
//
// 做法：把模型沿法線往外推一點，只畫背面（cull_front），不受光。
// 正面被原本的材質蓋住，於是只剩邊緣露出來，那圈露出來的就是描邊。

render_mode cull_front, unshaded, shadows_disabled, depth_draw_never;

// 描邊在畫面上的粗細。實際外推量會乘上「到鏡頭的距離」，
// 所以遠近看起來一樣粗——不這樣做的話，走遠一點描邊就細到看不見，
// 而「從遠處分辨剪影」正是這支 shader 存在的理由。
uniform float width : hint_range(0.0, 0.05) = 0.006;

uniform vec4 line_color : source_color = vec4(0.05, 0.04, 0.06, 1.0);

// 太薄的地方（手指、耳朵）外推會破洞，把最小厚度墊高一點可以蓋掉大部分。
uniform float min_width : hint_range(0.0, 0.05) = 0.012;

void vertex() {
	// MODELVIEW 之後的 z 就是到鏡頭的距離。用它縮放外推量，
	// 描邊的螢幕粗細才固定。
	float view_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	float scale = max(view_depth * width, min_width);
	// 蒙皮已經在這之前套用完了，所以 NORMAL 是「這一幀擺好姿勢之後」的法線，
	// 描邊會跟著動作一起變形，不會留在 T-pose 上。
	VERTEX += normalize(NORMAL) * scale;
}

void fragment() {
	ALBEDO = line_color.rgb;
}
