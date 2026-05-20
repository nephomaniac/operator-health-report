FROM quay.io/app-sre/ocm-container:latest

# Add tools not included in ocm-container
RUN dnf --assumeyes --nodocs install skopeo wget && dnf clean all

# Install yq (not included in ocm-container base)
ARG YQ_VERSION=v4.44.1
RUN curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Copy health check scripts
COPY collect_operator_health.sh /opt/health-report/
COPY collect_from_multiple_clusters.sh /opt/health-report/
COPY generate_html_report.sh /opt/health-report/
COPY get_app_interface_saas_refs.sh /opt/health-report/
COPY get_app_interface_saas_refs_with_images.sh /opt/health-report/

WORKDIR /opt/health-report

# Output directory for results (mount as volume)
RUN mkdir -p /results

ENTRYPOINT ["/bin/bash"]
