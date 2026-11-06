# Apple distribution signing intermediate

`AppleWWDRCAG3.cer` is Apple's public WWDR G3 intermediate, downloaded from
https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer.
It contains no private key. Apple Distribution certificates chain through G3;
see https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates/.

SHA-256: `dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f`.
Issued by Apple Root CA; expires February 20, 2030.

The release runner imports it as a certificate, without adding a trust override.
Trust still requires the existing Apple root. The runner's original keychains
are retained, and the signing identity must pass macOS code-signing validation
and match the certificates authorized by both provisioning profiles.
