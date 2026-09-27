#import "ALPNPin.h"

void GrabbitPinALPNToHTTP11(sec_protocol_options_t options) {
    sec_protocol_options_clear_tls_application_protocols(options);
    sec_protocol_options_add_tls_application_protocol(options, "http/1.1");
}
