/* Used by 36-redroid-vm-test.sh: load vendor GPU libraries the way Android's
 * EGL, Vulkan and gralloc loaders do (libvndksupport's android_load_sphal_library,
 * RTLD_NOW) and print the real dynamic linker's verdict for each one. Copy it to
 * /system/bin in a booted redroid container, so it runs in the system linker
 * section, where the "sphal" namespace is exported.
 *   sphal_loadtest /vendor/lib64/egl/libEGL_mesa.so /vendor/lib64/hw/vulkan.mesa.so ... */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
   void *vndk = dlopen("libvndksupport.so", RTLD_NOW);
   if (!vndk) {
      printf("FAIL libvndksupport.so: %s\n", dlerror());
      return 2;
   }
   void *(*load)(const char *, int) =
      (void *(*)(const char *, int))dlsym(vndk, "android_load_sphal_library");
   if (!load) {
      printf("FAIL android_load_sphal_library not found\n");
      return 2;
   }
   int bad = 0;
   for (int i = 1; i < argc; i++) {
      if (load(argv[i], RTLD_NOW | RTLD_LOCAL)) {
         printf("OK   %s\n", argv[i]);
      } else {
         printf("FAIL %s: %s\n", argv[i], dlerror());
         bad++;
      }
   }
   return bad ? 1 : 0;
}
