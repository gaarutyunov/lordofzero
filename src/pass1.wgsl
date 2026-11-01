//-----------------------------------------------------------------------------
// Vertex shader
//-----------------------------------------------------------------------------
struct VertexOutput {
  // Vertex position
  @builtin(position) Position : vec4<f32>,

  // UV coordinate
  @location(0) fragUV : vec2<f32>,
};

// Our vertex shader will recieve these parameters
struct Uniforms {
  // The view * orthographic projection matrix
  view_projection: mat4x4<f32>,

  // Total size of the sprite texture in pixels
  texture_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms : Uniforms;

// Effect parameters provided by the app via gfx.Sprite's user bind group (@group(1)).
// Must match `EffectUniforms` in App.zig.
struct Effect {
  // x = world time in seconds; yzw unused.
  params: vec4<f32>,
};

@group(1) @binding(0) var<uniform> effect : Effect;

// Sprite model transformation matrices
@group(0) @binding(1) var<storage, read> sprite_transforms: array<mat4x4<f32>>;

// Sprite UV coordinate transformation matrices. Sprite UV coordinates are (0, 0) at the top-left
// corner, and in pixels.
@group(0) @binding(2) var<storage, read> sprite_uv_transforms: array<mat4x4<f32>>;

// Sprite sizes, in pixels.
@group(0) @binding(3) var<storage, read> sprite_sizes: array<vec2<f32>>;

@vertex
fn vertMain(
  @builtin(vertex_index) VertexIndex : u32
) -> VertexOutput {
  // Our vertex shader will be called six times per sprite (2 triangles make up a sprite, so six
  // vertices.) The VertexIndex tells us which vertex we need to render, so we know e.g. vertices
  // 0-5 correspond to the first sprite, vertices 6-11 correspond to the second sprite, and so on.
  let sprite_transform = sprite_transforms[VertexIndex / 6];
  let sprite_uv_transform = sprite_uv_transforms[VertexIndex / 6];
  let sprite_size = sprite_sizes[VertexIndex / 6];

  // Imagine the vertices and UV coordinates of a card. There are two triangles, the UV coordinates
  // describe the corresponding location of each vertex on the texture. We hard-code the vertex
  // positions and UV coordinates here:
  let positions = array<vec2<f32>, 6>(
      vec2<f32>(0, 0), // left, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 1), // right, top
  );
  let uvs = array<vec2<f32>, 6>(
      vec2<f32>(0, 1), // left, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 0), // right, top
  );

  // Based on the vertex index, we determine which positions[n] and uvs[n] we need to use. Our
  // vertex shader is invoked 6 times per sprite, we need to produce the right vertex/uv coordinates
  // each time to produce a textured card.
  let pos_2d = positions[VertexIndex % 6];
  var uv = uvs[VertexIndex % 6];

  // Currently, our pos_2d and uv coordinates describe a card that covers 1px by 1px; and the UV
  // coordinates describe using the entire texture. We alter the coordinates to describe the
  // desired sprite location, size, and apply a subset of the texture instead of the entire texture.
  var pos = vec4<f32>(pos_2d * sprite_size, 0, 1); // normalized -> pixels
  pos = sprite_transform * pos; // apply sprite transform (pixels)
  pos = uniforms.view_projection * pos; // pixels -> normalized

  uv *= sprite_size; // normalized -> pixels
  uv = (sprite_uv_transform * vec4<f32>(uv, 1, 0)).xy; // apply sprite UV transform (pixels)
  uv /= sprite_size; // pixels -> normalized

  var output : VertexOutput;
  output.Position = pos;
  output.fragUV = uv;
  return output;
}

//-----------------------------------------------------------------------------
// Fragment shader
//-----------------------------------------------------------------------------
@group(0) @binding(4) var spriteSampler: sampler;
@group(0) @binding(5) var spriteTexture: texture_2d<f32>;

@fragment
fn fragMain(
  @location(0) uv: vec2<f32>
) -> @location(0) vec4<f32> {
    // Background image
    var c = textureSample(spriteTexture, spriteSampler, uv);
    if (c.a <= 0.0) {
        discard;
    }

    // Water reflections
    let time: f32 = effect.params.x + 50; // add 50s so that we're already into the animation starting
    let water_height = 0.8;
    if (uv.y > water_height) {
        let iuv = vec2<f32>(uv.x, ((1.-uv.y) + water_height) - (1.-water_height));

        let waves = fract(hash11(floor((iuv.y) * 200.)) * 2.0 + fract(time * 0.02 + iuv.x));
        let distortion = step(0.5, fract(hash11(floor((iuv.y) * 150.)) * 2.0 + fract((time * 0.2) + iuv.x * 6.)));
        let distortion_angle = (fract(hash11(floor((iuv.y) * 150.)) * 2.0 + fract(time * 0.01 + iuv.x * 0.2))) * 97.0721;
        let distortion_vec = vec2(sin(distortion_angle), cos(distortion_angle));

        return mix(
            vec4<f32>(0.),
            textureSample(spriteTexture, spriteSampler, vec2<f32>(iuv.x, iuv.y) + distortion_vec * distortion * 0.01) * 0.7,
            clamp(((1.-iuv.y) + 0.7) * 3.0, 0., 1.),
        );
    }
    return c;
}

fn hash11(p: f32) -> f32 {
	var p2: vec2<f32> = fract(vec2<f32>(p * 5.3983, p * 5.4427));
	p2 = p2 + (dot(p2.yx, p2.xy + vec2<f32>(21.5351, 14.3137)));
	return fract(p2.x * p2.y * 95.4337) * 0.5 + 0.5;
}
