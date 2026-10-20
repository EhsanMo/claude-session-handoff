# Reads stdin, writes stdout: a multi-line PEM private key block becomes one
# [REDACTED] line. A BEGIN with no END is redacted to EOF (fail closed).
/-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----/ && !inkey { inkey = 1 }
inkey {
  if ($0 ~ /-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----/) { print "[REDACTED]"; inkey = 0 }
  next
}
{ print }
END { if (inkey) print "[REDACTED]" }
