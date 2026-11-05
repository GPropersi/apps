FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
COPY www /www
EXPOSE 8080
USER 1000
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
