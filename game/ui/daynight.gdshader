shader_type canvas_item;
// 晨昏线：按太阳直射经度/赤纬计算昼夜与黄昏带

uniform float sun_lon = 116.0;  // 太阳直射经度（此处为正午）
uniform float decl = -21.0;     // 太阳赤纬（随月份变化，造成极昼极夜）

varying vec2 wpos;
const float MS = 7.0;           // 像素/度，与地图生成器一致

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float lon = wpos.x / MS - 180.0;
	float lat = 90.0 - wpos.y / MS;
	float H = radians(lon - sun_lon);
	float phi = radians(lat);
	float d = radians(decl);
	float cosz = sin(phi) * sin(d) + cos(phi) * cos(d) * cos(H);
	float night = smoothstep(0.08, -0.14, cosz);       // 夜半球
	float twil = smoothstep(0.16, 0.02, abs(cosz));    // 晨昏带
	vec3 ncol = vec3(0.012, 0.02, 0.05);
	vec3 dcol = vec3(0.95, 0.5, 0.18);
	float a = night * 0.5 + twil * 0.10;
	COLOR = vec4(mix(ncol, dcol, twil * 0.55), clamp(a, 0.0, 0.6));
}
