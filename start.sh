#!/usr/bin/env bash
set -eo pipefail

if [ ! -e private_ec256.pem ]; then
    printf "Create signing key\n"
    # generate a private key for a curve
    openssl ecparam -name prime256v1 -genkey -noout -out private_ec256.pem

    # generate corresponding public key
    openssl ec -in private_ec256.pem -pubout -out public_ec256.pem
fi

if [ ! -e satosa/backend.key ]; then
    printf "Create satosa saml2 backend certificates.\n"
    openssl req -x509 -newkey rsa:4096 -keyout satosa/backend.key -out satosa/backend.crt -sha256 -days 3650 -nodes -subj "/CN=satosa-issuer" -addext "subjectAltName=DNS:satosa-issuer"
fi
if [ ! -e satosa/metadata.key ]; then
    printf "Create satosa saml2 metadata sign certificates.\n"
    openssl req -x509 -newkey rsa:4096 -keyout satosa/metadata.key -out satosa/metadata.crt -sha256 -days 3650 -nodes -subj "/CN=satosa-issuer" -addext "subjectAltName=DNS:satosa-issuer"
fi

if [ ! -e simplesamlphp/webcert/privkey.pem ]; then
    printf "Create simplesamlphp web certificates.\n"
    [ -d simplesamlphp/webcert ] || mkdir simplesamlphp/webcert
    openssl req -x509 -newkey rsa:4096 -keyout simplesamlphp/webcert/privkey.pem -out simplesamlphp/webcert/cert.pem -sha256 -days 3650 -nodes -subj "/CN=simplesamlphp" -addext "subjectAltName=DNS:simplesamlphp"
    cp simplesamlphp/webcert/cert.pem satosa/simplesaml_webcert.pem
fi
if [ ! -e simplesamlphp/samlcert/saml_metadata.key ]; then
    printf "Create simplesamlphp saml certificates.\n"
    [ -d simplesamlphp/samlcert ] || mkdir simplesamlphp/samlcert
    openssl req -x509 -newkey rsa:4096 -keyout simplesamlphp/samlcert/saml_metadata.key -out simplesamlphp/samlcert/saml_metadata.pem -sha256 -days 3650 -nodes -subj "/CN=simplesamlphp" -addext "subjectAltName=DNS:simplesamlphp"
    cp simplesamlphp/samlcert/saml_metadata.pem satosa/

    # Create an empty placeholder file to prevent Docker from mounting it as a directory
    touch simplesamlphp/satosa-issuer.xml
    docker compose run --rm \
    --entrypoint /bin/bash \
    -v "$(pwd)/simplesamlphp/samlcert:/var/simplesamlphp/samlcert" \
    simplesamlphp \
    -c "chgrp www-data /var/simplesamlphp/samlcert/saml_metadata.key && ls -l /var/simplesamlphp/samlcert/saml_metadata.key" && \
    echo 'Group changed to www-data successfully!'
fi

source .env
sed -i s/ISSUER_HOSTNAME/${ISSUER_HOSTNAME}/g satosa/plugins/saml2_backend.yaml
sed -i s#ISSUER_FQDN#${ISSUER_FQDN}#g config.yaml

if [ ! -e satosa/metadata/backend.xml ]; then
    printf "Extracting SAML metadata from SATOSA for SimpleSAMLphp configuration.\n"
    mkdir -p satosa/metadata
    docker compose run --no-deps --rm \
        -w /etc/satosa \
        -v $(pwd)/bootstrap_files/dummy_md.xml:/tmp/dummy_md.xml \
        -v $(pwd)/bootstrap_files/dummy_saml2_backend.yaml:/etc/satosa/plugins/saml2_backend.yaml \
        -v $(pwd)/bootstrap_files/dummy_oidc_frontend.yaml:/etc/satosa/plugins/oidc_frontend.yaml \
        --entrypoint satosa-saml-metadata satosa --no-sign --dir metadata /etc/satosa/proxy_conf.yaml
    cp satosa/metadata/backend.xml simplesamlphp/satosa-issuer.xml
fi



printf "Starting vc docker-compose services\n"
docker compose -f docker-compose.yaml up -d --remove-orphans
