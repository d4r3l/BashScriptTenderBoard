# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-03-16

### Added
- Complete zero-downtime deployment script for AWS EC2/ALB
- Rolling deployment strategy with health checks
- Automatic rollback on failure
- AWS SSM Session Manager integration (no SSH required)
- Comprehensive logging with rotation
- Configuration management via external config file
- Retry logic with exponential backoff
- Multi-language application startup script (Node.js, Python, Java, Go)
- IAM policy template
- GitHub Actions and Jenkins CI/CD examples
- MIT License

### Changed
- Initial release for BashScriptTenderBoard repository

## [2.0.0] - 2026-01-15

### Added
- Production-ready deployment automation
- ALB integration for load balancer management
- S3 artifact storage with pre-signed URLs
- Health check validation per instance

## [1.0.0] - 2025-12-01

### Added
- Initial script development
- Basic deployment functionality
- Error handling and logging

---

**Author:** Muhammad Reza  
**Email:** darel.rv@gmail.com  
**GitHub:** https://github.com/d4r3l/
