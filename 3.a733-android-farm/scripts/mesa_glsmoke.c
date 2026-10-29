/* Used by 24-mesa-shim-probe.sh: drive the CPU side of Zink + PowerVR on the
 * no-op drm-shim with GLES 3.1 work typical of Android apps (texturing, UBOs,
 * discard, blending, MRT, instancing, compute, readback). Pixels are not
 * checked (nothing runs on a GPU); the point is that shader compilation,
 * pipeline creation, command recording and submission don't crash or assert. */
#include <stdio.h>
#include <stdlib.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>

static int fails;

static GLuint shader(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[1024];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      printf("compile failed: %s\n", log);
      fails++;
   }
   return s;
}

static GLuint program(const char *vs, const char *fs)
{
   GLuint p = glCreateProgram();
   glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
   glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
   glLinkProgram(p);
   GLint ok = 0;
   glGetProgramiv(p, GL_LINK_STATUS, &ok);
   if (!ok) {
      printf("link failed\n");
      fails++;
   }
   return p;
}

static const char *vs_src =
   "#version 310 es\n"
   "layout(location = 0) in vec2 pos;\n"
   "layout(location = 1) in vec2 uv;\n"
   "layout(std140, binding = 0) uniform U { mat4 mvp; vec4 tint; };\n"
   "out vec2 v_uv;\n"
   "void main() {\n"
   "  v_uv = uv;\n"
   "  gl_Position = mvp * vec4(pos + vec2(float(gl_InstanceID) * 0.01), 0.0, 1.0);\n"
   "}\n";

static const char *fs_src =
   "#version 310 es\n"
   "precision mediump float;\n"
   "layout(std140, binding = 0) uniform U { mat4 mvp; vec4 tint; };\n"
   "uniform sampler2D tex;\n"
   "in vec2 v_uv;\n"
   "layout(location = 0) out vec4 c0;\n"
   "layout(location = 1) out vec4 c1;\n"
   "void main() {\n"
   "  vec4 t = texture(tex, v_uv);\n"
   "  if (t.a < 0.1) discard;\n"
   "  c0 = t * tint;\n"
   "  c1 = vec4(v_uv, dFdx(v_uv.x), 1.0);\n"
   "}\n";

static const char *cs_src =
   "#version 310 es\n"
   "layout(local_size_x = 64) in;\n"
   "layout(std430, binding = 1) buffer B { float v[]; };\n"
   "shared float s[64];\n"
   "void main() {\n"
   "  uint i = gl_GlobalInvocationID.x;\n"
   "  s[gl_LocalInvocationID.x] = v[i];\n"
   "  barrier();\n"
   "  v[i] = s[63u - gl_LocalInvocationID.x] * 2.0;\n"
   "}\n";

int main(void)
{
   PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   EGLDisplay dpy = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
   if (!eglInitialize(dpy, NULL, NULL))
      return 1;
   eglBindAPI(EGL_OPENGL_ES_API);
   EGLint ca[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ca);
   if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      printf("no GLES 3.1 context\n");
      return 1;
   }
   printf("%s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER));

   const int w = 720, h = 1280;
   GLuint fbo, rt[2], tex;
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glGenTextures(2, rt);
   for (int i = 0; i < 2; i++) {
      glBindTexture(GL_TEXTURE_2D, rt[i]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_TEXTURE_2D, rt[i], 0);
   }
   GLenum bufs[] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
   glDrawBuffers(2, bufs);
   if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      printf("framebuffer incomplete\n");
      fails++;
   }

   unsigned char *pix = calloc(256 * 256, 4);
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, pix);
   glGenerateMipmap(GL_TEXTURE_2D);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);

   GLuint prog = program(vs_src, fs_src);
   float verts[] = { -1, -1, 0, 0, 1, -1, 1, 0, -1, 1, 0, 1, 1, 1, 1, 1 };
   GLuint vao, vbo, ubo, ssbo;
   glGenVertexArrays(1, &vao);
   glBindVertexArray(vao);
   glGenBuffers(1, &vbo);
   glBindBuffer(GL_ARRAY_BUFFER, vbo);
   glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (void *)0);
   glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (void *)8);
   glEnableVertexAttribArray(0);
   glEnableVertexAttribArray(1);
   float u[20] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1 };
   glGenBuffers(1, &ubo);
   glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
   glBufferData(GL_UNIFORM_BUFFER, sizeof(u), u, GL_DYNAMIC_DRAW);

   GLuint cs = glCreateProgram();
   glAttachShader(cs, shader(GL_COMPUTE_SHADER, cs_src));
   glLinkProgram(cs);
   float data[1024] = { 0 };
   glGenBuffers(1, &ssbo);
   glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, ssbo);
   glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(data), data, GL_DYNAMIC_COPY);

   glEnable(GL_BLEND);
   glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
   for (int frame = 0; frame < 120; frame++) {
      glViewport(0, 0, w, h);
      glClearColor(0.1f, 0.2f, 0.3f, 1.0f);
      glClear(GL_COLOR_BUFFER_BIT);
      glUseProgram(prog);
      u[16] = (float)(frame % 10) / 10.0f;
      glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(u), u);
      glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, 16);
      glUseProgram(cs);
      glDispatchCompute(1024 / 64, 1, 1);
      glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
      if (frame % 30 == 29) {
         glReadBuffer(GL_COLOR_ATTACHMENT0);
         glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, pix);
      }
      glFlush();
   }
   glFinish();
   GLenum err = glGetError();
   if (err != GL_NO_ERROR) {
      printf("GL error 0x%x\n", err);
      fails++;
   }
   printf("120 frames: %s\n", fails ? "FAILED" : "OK");
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   return fails ? 1 : 0;
}
