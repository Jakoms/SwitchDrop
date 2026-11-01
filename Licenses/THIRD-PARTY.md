# Third-party libraries

SwitchDrop bundles libmtp 1.1.23 and libusb 1.0.30 as dynamically linked libraries. Both are distributed under LGPL-2.1; see the accompanying COPYING and AUTHORS files. SwitchDrop imposes no restriction on modification or reverse engineering for debugging modifications to these libraries.

Complete upstream source archives are included in ../ThirdParty in the full SwitchDrop distribution. The release libraries are built from these archives for Apple Silicon, with MACOSX_DEPLOYMENT_TARGET=13.0. libusb is configured with ac_cv_func_pipe2=no for compatibility with older macOS SDK/runtime combinations. libmtp is built with --disable-mtpz and the included SwitchDrop directory-listing adapter.

## libmtp

Source: https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz
SHA-256: 74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed

## libusb

Source: https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
SHA-256: fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf

## Relinking

Run Source/build-deps.sh to rebuild the libraries from the included archives. The complete adapter is Source/libmtp-dbi-extension.inc; the script appends it to libmtp.c and exports LIBMTP_SwitchDrop_List. Source/build.sh then links and signs the helper and app. A replacement libmtp must include this documented adapter API or the helper can be rebuilt to use its upstream listing API. Replace the compatible dylibs under Contents/Frameworks and set their install names to @loader_path/libusb-1.0.0.dylib and @rpath/libmtp.9.dylib as shown in Source/build.sh. Re-sign the modified libraries, helper and app with codesign --force --sign -. The application is not hardened or sandboxed.

Project and complete corresponding source: https://github.com/Jakoms/SwitchDrop
Source archives for each release: https://github.com/Jakoms/SwitchDrop/releases
