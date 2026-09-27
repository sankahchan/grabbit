#import <Foundation/Foundation.h>
#import <Security/Security.h>

/// Restricts a TLS configuration's ALPN advertisement to HTTP/1.1 only.
///
/// Implemented in ObjC because the underlying sec_protocol_options ALPN
/// functions are not visible to Swift. Without this pinning, a server may
/// negotiate HTTP/2 via ALPN and then the raw HTTP/1.1 bytes spoken by
/// HTTP1Client would be garbage to it.
void GrabbitPinALPNToHTTP11(sec_protocol_options_t options);
