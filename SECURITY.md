# Security policy

Exa handles very personal data — messages, email, calendar — and can act on a
phone with powerful permissions. We take security reports seriously and
appreciate responsible disclosure.

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or
pull requests.**

1. Preferred: use GitHub's private reporting — go to the **Security** tab of
   this repository and choose **Report a vulnerability**.
2. Or email [info@brightforgett.com](mailto:info@brightforgett.com) with the
   subject line `SECURITY: Exa`.

Please include:

- what the problem is and what an attacker could do with it;
- steps to reproduce, or a proof of concept;
- the Exa version or commit, Android version and device model.

## What to expect

- We acknowledge reports within **3 business days**.
- We aim to confirm the issue and share a fix plan within **14 days**.
- We will credit you in the release notes unless you prefer to stay
  anonymous.
- Please give us reasonable time to release a fix before disclosing the
  issue publicly. We aim for no more than **90 days**.

## Supported versions

Exa is in alpha. Security fixes are made on the latest release only.

## Scope

In scope: this repository's code, including the Android app, its native
plugins and the provisioning scripts.

Out of scope: vulnerabilities in third-party AI providers, Android itself, or
third-party apps Exa reads from (report those to their vendors), and attacks
that require an already-unlocked phone that the attacker physically controls
with Exa's device-owner mode enabled by its owner.
