// Stand-in for libxml2.so.2, so the image doesn't need libxml2 and ICU (~38 MB).
// Ubuntu's libLLVM links libxml2 only for llvm::WindowsManifest (llvm-mt and
// lld-link's manifest merging), which nothing on the device uses. trim.sh
// checks that these cover every libxml2 symbol libLLVM needs.
#include <stdlib.h>

#define STUB(name) void name(void) { abort(); }

STUB(xmlAddChild)
STUB(xmlCopyNamespace)
STUB(xmlDocDumpFormatMemoryEnc)
STUB(xmlDocGetRootElement)
STUB(xmlDocSetRootElement)
STUB(xmlFreeDoc)
STUB(xmlFreeNode)
STUB(xmlFreeNs)
STUB(xmlNewDoc)
STUB(xmlNewNs)
STUB(xmlNewProp)
STUB(xmlReadMemory)
STUB(xmlSetGenericErrorFunc)
STUB(xmlStrdup)
STUB(xmlUnlinkNode)

// xmlFree is a function pointer variable in libxml2
static void stub_free(void *p) { (void)p; abort(); }
void (*xmlFree)(void *) = stub_free;
