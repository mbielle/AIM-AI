#!/usr/bin/env python3
"""Validate public Supabase client configuration before a build touches artifacts.

Read AIM_SUPABASE_URL and AIM_SUPABASE_PUBLIC_KEY from the environment only.
Never echo their values. JWT role inspection does not authenticate a JWT.
"""
import base64
import binascii
import json
import os
import re
import sys
import urllib.parse


def validate_origin(value):
    value = value.strip()
    try:
        origin = urllib.parse.urlsplit(value)
        port = origin.port
        if (not value or any(character.isspace() for character in value) or '\\' in value
                or origin.scheme.lower() != 'https' or not origin.hostname
                or origin.username is not None or origin.password is not None
                or origin.path not in ('', '/') or '?' in value or '#' in value
                or (port is not None and not 1 <= port <= 65535)
                or origin.netloc.endswith(':')):
            raise ValueError()
    except ValueError:
        raise ValueError('AIM_SUPABASE_URL must be a bare HTTPS origin without credentials, path, query or fragment') from None


def validate_public_key(value):
    value = value.strip()
    if not value or value.startswith(('sbp_', 'sb_secret_')):
        raise ValueError('AIM_SUPABASE_PUBLIC_KEY must be a publishable or anon key, never a privileged key')
    if value.startswith('sb_publishable_'):
        if len(value) > len('sb_publishable_') and not any(character.isspace() for character in value):
            return
        raise ValueError('AIM_SUPABASE_PUBLIC_KEY is not a valid publishable key')
    segments = value.split('.')
    try:
        if len(segments) != 3 or any(not re.fullmatch(r'[A-Za-z0-9_-]+={0,2}', segment) for segment in segments):
            raise ValueError()
        payload = segments[1]
        decoded = base64.b64decode(payload + '=' * (-len(payload) % 4), altchars=b'-_', validate=True)
        claims = json.loads(decoded)
        if not isinstance(claims, dict) or claims.get('role') != 'anon':
            raise ValueError()
    except (ValueError, binascii.Error, UnicodeDecodeError):
        raise ValueError('AIM_SUPABASE_PUBLIC_KEY must be a publishable or anon-role key') from None


def main():
    if len(sys.argv) != 1:
        raise ValueError('Set AIM_SUPABASE_URL and AIM_SUPABASE_PUBLIC_KEY in the environment; no configuration arguments are accepted')
    url, key = os.environ.get('AIM_SUPABASE_URL', ''), os.environ.get('AIM_SUPABASE_PUBLIC_KEY', '')
    if not url and not key:
        return
    if not url or not key:
        raise ValueError('AIM account builds require the public Supabase URL and key together')
    validate_origin(url)
    validate_public_key(key)


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
