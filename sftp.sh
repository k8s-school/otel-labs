#!/bin/bash

# Publish the OpenTelemetry training site to https://k8s-school.fr/labs/otel
#
# The whole site is replaced at every run, pdf/ included: the slides are
# regenerated from slides/*.md by md2pdf.sh, so nothing here is worth
# preserving between deployments. The build is uploaded to a temporary
# directory and moved into place, so the live site is never left half-updated.

set -e
set -x

DIR=$(cd "$(dirname "$0")"; pwd -P)

SERVER_DIR="www/labs/otel"
SERVER_TMP_DIR="tmp-otel"
LOCAL_DIR="$DIR/public"
PDF_DIR="$LOCAL_DIR/pdf"

. "$DIR/env-creds.sh"

hugo --minify

# Slides: built by slides/md2pdf.sh, served from pdf/ behind basic auth
if ! ls "$DIR"/slides/*.pdf > /dev/null 2>&1; then
    >&2 echo "ERROR: no slide PDF found, run slides/md2pdf.sh first"
    exit 1
fi
mkdir -p "$PDF_DIR"
cp "$DIR"/slides/*.pdf "$PDF_DIR"

# Password protection for pdf/
if [ -z "$HTACCESS_USER" ]; then
    >&2 echo "ERROR: undefined HTACCESS_USER in env-creds.sh"
    exit 1
fi
sed "s/<LOGIN>/$SERVER_USER/g" "$DIR/deploy/pdf.htaccess" > "$PDF_DIR/.htaccess"
htpasswd -bc "$PDF_DIR/.htpasswd" "$HTACCESS_USER" "$HTACCESS_PASS"

yafc <<**
open fish://"$SERVER_USER":$SERVER_PASS@"$SERVER"
mkdir "$SERVER_TMP_DIR"
cd "$SERVER_TMP_DIR"
put -rf $LOCAL_DIR/*
mkdir pdf
cd pdf
put -f $PDF_DIR/.htaccess
put -f $PDF_DIR/.htpasswd
cd
rm -rf "$SERVER_DIR"
mv "$SERVER_TMP_DIR" "$SERVER_DIR"
close
**
