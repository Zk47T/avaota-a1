/* Used by 24-mesa-shim-probe.sh: on a surfaceless EGL display, try GLES and
 * desktop GL contexts from the highest version down and print what each one
 * gets. With EXTS=1 it also prints the GLES 3.1 extension string. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static void try_ctx(EGLDisplay dpy, EGLConfig cfg, EGLenum api, int major, int minor, int core)
{
   eglBindAPI(api);
   EGLint attr[16]; int i = 0;
   attr[i++] = EGL_CONTEXT_MAJOR_VERSION; attr[i++] = major;
   attr[i++] = EGL_CONTEXT_MINOR_VERSION; attr[i++] = minor;
   if (api == EGL_OPENGL_API && core) { attr[i++] = EGL_CONTEXT_OPENGL_PROFILE_MASK; attr[i++] = EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT; }
   attr[i++] = EGL_NONE;
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, attr);
   if (ctx == EGL_NO_CONTEXT) { printf("%s %d.%d%s: no context (0x%x)\n", api == EGL_OPENGL_API ? "GL" : "GLES", major, minor, core ? " core" : "", eglGetError()); return; }
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
   if (getenv("EXTS") && api == EGL_OPENGL_ES_API && major == 3 && minor == 1) printf("EXT %s\n", glGetString(GL_EXTENSIONS));
   printf("%s %d.%d%s: OK\n  GL_VERSION  %s\n  GL_RENDERER %s\n  GLSL        %s\n", api == EGL_OPENGL_API ? "GL" : "GLES", major, minor, core ? " core" : "",
          glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglDestroyContext(dpy, ctx);
}

int main(void)
{
   PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   EGLDisplay dpy = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
   EGLint maj, min;
   if (!eglInitialize(dpy, &maj, &min)) { printf("eglInitialize failed 0x%x\n", eglGetError()); return 1; }
   printf("EGL %d.%d vendor=%s\n", maj, min, eglQueryString(dpy, EGL_VENDOR));
   EGLint ca[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
   EGLConfig cfg; EGLint n = 0;
   eglChooseConfig(dpy, ca, &cfg, 1, &n);
   if (!n) { EGLint none[] = { EGL_NONE }; eglChooseConfig(dpy, none, &cfg, 1, &n); }
   int es[][2] = { {3,2}, {3,1}, {3,0}, {2,0} };
   for (int k = 0; k < 4; k++) try_ctx(dpy, n ? cfg : EGL_NO_CONFIG_KHR, EGL_OPENGL_ES_API, es[k][0], es[k][1], 0);
   int gl[][2] = { {4,6}, {4,0}, {3,3}, {3,2}, {3,1}, {3,0} };
   for (int k = 0; k < 6; k++) try_ctx(dpy, n ? cfg : EGL_NO_CONFIG_KHR, EGL_OPENGL_API, gl[k][0], gl[k][1], gl[k][0] > 3 || gl[k][1] >= 2);
   eglTerminate(dpy);
   return 0;
}
