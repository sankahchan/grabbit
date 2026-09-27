#import "ALPNPin.h"

void GrabbitPinALPNToHTTP11(sec_protocol_options_t options) {
    // There is no API to clear the ALPN list, but none is needed: a raw
    // NWConnection's default ALPN list is empty, so adding http/1.1 pins
    // negotiation to HTTP/1.1. (Without ALPN a server cannot legally speak
    // h2 per RFC 7540 §3.4, so this also defeats h2 multiplexing.)
    sec_protocol_options_add_tls_application_protocol(options, "http/1.1");
}
