# Autocaliweb

Autocaliweb is a web app that offers a clean and intuitive interface for browsing, reading, and downloading eBooks using a valid [Calibre](https://calibre-ebook.com) database.

[![License](https://img.shields.io/github/license/gelbphoenix/autocaliweb?style=flat-square)](https://github.com/gelbphoenix/autocaliweb/blob/master/LICENSE)
![Version](https://img.shields.io/github/v/release/gelbphoenix/autocaliweb?display_name=release&style=flat-square&logo=github&color=%23008000)
![Commit Activity](https://img.shields.io/github/commit-activity/w/gelbphoenix/autocaliweb?logo=github&style=flat-square&label=commits)
[![Docker Pulls](https://img.shields.io/docker/pulls/gelbphoenix/autocaliweb?style=flat-square&logo=docker)](https://hub.docker.com/r/gelbphoenix/autocaliweb)

<details>
<summary><strong>Table of Contents</strong> (click to expand)</summary>

1. [About](#autocaliweb)
2. [Features](#features)
3. [Installation](#installation)
   - [Installation via Docker (recommended)](#installation-via-docker-recommended)
   - [Manual-Installation - without Docker](#manual-installation-without-docker)
   - [After Installation](#after-installation)
   - [Deploy Requirements](#deploy-requirements)
4. [Troubleshooting](#troubleshooting)
5. [Contributor Recognition](#contributor-recognition)
6. [Contact](#contact)
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
- eBook metadata editing and deletion support
- Metadata download from various sources (extensible via plugins)
- eBook conversion through Calibre binaries
- eBook download restriction to logged-in users
- Public user registration support
- Send eBooks to E-Readers with a single click
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
- ISBNDB and Hardcover as additional providers for metadata
- Syncing reading process to [Hardcover.app](https://hardcover.app/) (Only with Kobo E-Readers)

### Features only in Autocaliweb

- Usage of `DOCKER_MODS` from sources like linuxserver.io and others
- Listing of Author information and other books from Goodreads or Hardcover
- User en- or disabling of the Kobo Sync and/or Overdrive tabs when using Kobo sync
- Support for custom OIDC providers (with support for an .well-known link)

## Installation

### Installation via Docker (recommended)

#### Quick Install

1. Download the Docker Compose template file to the folder where Autocaliweb should have it's data (e.g. /opt/autocaliweb) using the command below:

```
curl -Lo ./docker-compose.yml https://raw.githubusercontent.com/gelbphoenix/autocaliweb/master/docker-compose.yml
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
### Manual installation without Docker  
For manual installation without docker see [Manual Installation](https://github.com/gelbphoenix/autocaliweb/wiki/Manual-Installation).  

## After Installation

1. **Access Autocaliweb**: Open your browser and navigate to: http://localhost:8083 or http://localhost:8083/opds for the OPDS catalog.
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

## Deploy Requirements

- Docker version 27.5.1 (minimum)
- Docker Compose version 2.33.1 (minimum)

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

## Contact

**To be build**

## Contributing to Autocaliweb

To contribute, please check our [Contributing Guidelines](https://github.com/gelbphoenix/autocaliweb/blob/master/CONTRIBUTING.md). We welcome issues, feature requests, and pull requests from the community.

### Reporting Bugs

If you encounter bugs or issues, please report them in the [issues section](https://github.com/gelbphoenix/autocaliweb/issues) of the repository. Be sure to include detailed information about your setup and the problem encountered.

### Feature Requests

We welcome suggestions for new features. Please create a new issue in the repository to discuss your ideas.

## Additional Resources

- **Documentation**: _Needs to be build_
- **Community Contributions**: Explore the [community contributions](https://github.com/gelbphoenix/autocaliweb/pulls) to see ongoing work and how you can get involved.

---

Thank you for using Autocaliweb! We hope you enjoy managing your eBook library with our tool.
