# ![Logo Light](https://github.com/gelbphoenix/autocaliweb/raw/refs/heads/main/cps/static/icon-light.svg) Autocaliweb

Autocaliweb is a web app that offers a clean and intuitive interface for browsing, reading, and downloading eBooks using a valid [Calibre](https://calibre-ebook.com) database.

[![License](https://img.shields.io/github/license/gelbphoenix/autocaliweb?style=flat-square)](https://github.com/gelbphoenix/autocaliweb/blob/main/LICENSE)
[![Release](https://img.shields.io/github/v/release/gelbphoenix/autocaliweb?display_name=release&style=flat-square&logo=github&color=%23008000)](https://github.com/gelbphoenix/autocaliweb/releases/latest/)
[![Commit Activity](https://img.shields.io/github/commit-activity/w/gelbphoenix/autocaliweb?logo=github&style=flat-square&label=commits)](https://github.com/gelbphoenix/autocaliweb/commits/)
[![Docker Pulls](https://img.shields.io/docker/pulls/gelbphoenix/autocaliweb?style=flat-square&logo=docker)](https://hub.docker.com/r/gelbphoenix/autocaliweb)

<details>
<summary><strong>Table of Contents</strong> (click to expand)</summary>

1. [About](#autocaliweb)
2. [Features](#features)
3. [Installation](#installation)
   - [Installation via Docker (recommended)](#installation-via-docker-recommended)
   - [Manual installation without Docker (on your own risk)](#manual-installation-without-docker-on-your-own-risk)
   - [Proxmox VE Script](#proxmox-ve-script)
   - [After Installation](#after-installation)
   - [Deploy Requirements](#deploy-requirements)
4. [Troubleshooting](#troubleshooting)
5. [Contributor Recognition](#contributor-recognition)
6. [Documentation](#documentation)
7. [Contributing to Autocaliweb](#contributing-to-autocaliweb)

</details>

_This software is a fork of [Calibre-Web](https://github.com/janeczku/calibre-web) and [Calibre-Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated) and licensed under the GPL v3 License._

## Features

- Modern and responsive Bootstrap 3 HTML5 interface
- Full graphical setup
- Comprehensive user management with fine-grained per-user permissions
- Admin interface
- Multilingual user interface supporting 20+ languages
- OPDS feed for eBook reader apps
- Advanced search and filtering options
- Custom book collection (shelves) creation
- Bulk shelf management from the Books List (multi-select add/remove)
- eBook metadata editing and deletion support
- Metadata download from various sources (extensible via plugins)
- eBook conversion through Calibre binaries
- eBook download restriction to logged-in users
- Public user registration support
- Send eBooks to E-Readers
- Sync Kobo devices with your Calibre library
- In-browser eBook reading support for multiple formats
- Upload new books in various formats, including audio formats
- Calibre Custom Columns support
- Content hiding based on categories and Custom Column content per user
- Self-update capability
- "Magic Link" login for easy access on eReaders
- LDAP, Google/GitHub OAuth, and proxy authentication support
- Auto Ingest, Conversion, Metadata and Cover Enforcement and Backup services
- Automatic EPub Fixer service
- Auto-detection of your library
- Automatic Setup
- Server Stats tracking
- Easy theme switching
- Batch edits of books
- ISBNDB, Amazon JP and Hardcover as additional metadata providers
- Syncing reading process to [Hardcover.app](https://hardcover.app/) (Only with Kobo E-Readers)
- Split library support
- Support for CLI compatible Calibre plugins
- Support for syncing with the KOReader document viewer
- Setting Automerge option
- Automatically fetch metadata for newly added books
- Automatically send new books to your E-Reader

### Features only in Autocaliweb

- Usage of `DOCKER_MODS` from sources like linuxserver.io and others
- Listing and caching of Author information and other books from Goodreads or Hardcover
- User en- or disabling of the Kobo Sync and Overdrive tabs as well as the Instapaper integration when using Kobo sync
- Support for custom OIDC providers (with support for /.well-known/openid-configuration)
- Support for manual installation (without docker specific features)
- LitRes as metadata provider
- Multi email selection for the Send eBooks to E-Readers function
- Management system for duplicate books
- Generate generic covers for books

## Installation

> [!NOTE]
> Installation on Windows with Docker Desktop is not supported. Installation on Windows Subsystem for Linux (WSL) is on your own risk.

### Installation via Docker (recommended)

#### Quick Install

1. Download the Docker Compose template file to the folder where Autocaliweb should have it's data (e.g. /opt/autocaliweb) using the command below:

```
curl -Lo ./docker-compose.yml https://raw.githubusercontent.com/gelbphoenix/autocaliweb/main/docker-compose.yml
```

2.  Edit the compose file using the comments to help, filling in your Timezone and desired binds

3.  Navigate to where you downloaded the Compose file and run:

```
docker compose up -d
```

And that's you off to the races! Continue with the [things after installation](#after-installation).

#### Using Docker compose:

```yml
services:
  autocaliweb:
    image: gelbphoenix/autocaliweb:latest
    container_name: autocaliweb
    restart: unless-stopped
    ports:
      - "8083:8083"
    environment:
      - TZ=Etc/UTC # Change to your specific timezone (e.g. Europe/Berlin, America/Denver)
      - PUID=1000
      - PGID=1000
    volumes:
      - /path/to/config:/config
      - /path/to/book/ingest:/acw-book-ingest
      - /path/to/library:/calibre-library
    stop_signal: SIGINT
    stop_grace_period: 15s
```

### Manual installation without Docker (on your own risk)

If you want to install Autocaliweb on your server without setting up Docker and Docker compose you can follow these steps (For an extensive installation and the uninstall guide look at the [relating wiki article](https://github.com/gelbphoenix/autocaliweb/wiki/Manual-Installation)):

1. Download the `manual_install_acw.sh` file with the following command and check it:

```bash
curl -Lo ./manual_install_acw.sh https://github.com/gelbphoenix/autocaliweb/raw/refs/heads/main/scripts/manual_install_acw.sh
```

2. Make `manual_install_acw.sh` executeable and run it as root:

```bash
sudo chmod +x ./manual_install_acw.sh && sudo ./manual_install_acw.sh
```

3. Follow now the next steps that are shown after install_autocaliweb run successfully

### Proxmox VE Script

> [!NOTE]
> This script was created by and maintained by team of the [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/). The page of the script is found [here](https://community-scripts.github.io/ProxmoxVE/scripts?id=autocaliweb) and support for the script is provided by that team.

To install Autocaliweb on Proxmox VE you can also use this script from the Proxmox VE Helper-Scripts:

<details>
<summary>GitHub</summary>

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/autocaliweb.sh)"
```

</details>

<details>
<summary>Gitea (Look on the page for the script for when you have to use this link)</summary>

```bash
bash -c "$(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/ct/autocaliweb.sh)"
```

</details>

You can (and generally should) check and understand external scripts.

### Deploy Requirements

#### For the deployment via docker

- Docker version 27.5.1 (minimum)
- Docker Compose version 2.33.1 (minimum)

#### For the manual installation

See the requirements [here](https://github.com/gelbphoenix/autocaliweb/wiki/Manual-Installation#prerequisites)

#### For the [Proxmox VE Script](#proxmox-ve-script)

- An updated Proxmox VE install

## After Installation

1. **Access Autocaliweb**: Open your browser and navigate to: http://localhost:8083 (http://localhost:8083/opds for the OPDS catalog).
2. **Log in with the default admin credentials**:
   ```
   Username: admin
   Password: admin123
   ```
3. Configure your Autocaliweb instance via the Admin Page

- A guide to what all of the stock CW Settings do can be found [here](https://github.com/janeczku/calibre-web/wiki/Configuration#basic-configuration)
- Make sure `Enable Uploads` is enabled in `Settings -> Basic Configuration -> Feature Configuration`

4. **Google Drive Integration**: For hosting your Calibre library on Google Drive, refer to the [Google Drive integration guide of Calibre-Web](https://github.com/janeczku/calibre-web/wiki/G-Drive-Setup#using-google-drive-integration).

> [!IMPORTANT] > **If you are migrating from Calibre-Web Automated please ensure that your cwa.db is renamed acw.db before start to load your existing settings**

## Troubleshooting

- **Common Issues**:
  - If you experience issues starting the application, check the log files located in the `logs` directory for error messages.
  - If eBooks fail to load, verify that the `Location of Calibre database` is correctly set and that the database file is accessible.

- **Configuration Errors**: Ensure that your Calibre database is compatible and properly formatted. Refer to the Calibre documentation for guidance on maintaining the database.

- **Performance Problems**:
  - If the application is slow, consider increasing the allocated resources (CPU/RAM) to your server or optimizing the Calibre database by removing duplicates and unnecessary entries.
  - Regularly clear the cache in your web browser to improve loading times.

- **User Management Issues**: If users are unable to log in or register, check the user permission settings in the admin interface. Ensure that registration is enabled and that users are being assigned appropriate roles.

## Contributor Recognition

We would like to thank all the [contributors](https://github.com/gelbphoenix/autocaliweb/graphs/contributors) and maintainers of Autocaliweb for their valuable input and dedication to the project. Your contributions are greatly appreciated.

## Documentation

Autocaliweb has an **not finished** documentation in the [wiki of this repository](https://github.com/gelbphoenix/autocaliweb/wiki)

## Contributing to Autocaliweb

To contribute, please check our [Contributing Guidelines](https://github.com/gelbphoenix/autocaliweb/blob/main/CONTRIBUTING.md). We welcome issues, feature requests, and pull requests from the community.

### JavaScript linting (ESLint)

This repository includes a modern ESLint v9 setup (flat config) for the browser JavaScript under `cps/static/js/`.

- Install dev dependencies: `npm install`
- Run lint: `npm run lint`
- Run lint (CI alias): `npm run lint:ci`
- Auto-fix what ESLint can: `npm run lint:fix`
- Fail the build on any warnings (stricter mode): `npm run lint:strict`

Configuration lives in `eslint.config.js`.

### Reporting Bugs

If you encounter bugs or issues, please report them in the [issues section](https://github.com/gelbphoenix/autocaliweb/issues) of the repository. Be sure to include detailed information about your setup and the problem encountered.

### Feature Requests

We welcome suggestions for new features. Please create a new issue in the repository to discuss your ideas.

## Additional Resources

- **Documentation**: Find the documentation in the [wiki of this repository](https://github.com/gelbphoenix/autocaliweb/wiki)
- **Community Contributions**: Explore the [community contributions](https://github.com/gelbphoenix/autocaliweb/pulls) to see ongoing work and how you can get involved.

---

Thank you for using Autocaliweb! We hope you enjoy managing your eBook library with our tool.
