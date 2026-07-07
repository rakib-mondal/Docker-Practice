FROM nginx:1.27-alpine

# Remove the default Nginx configuration
RUN rm /etc/nginx/conf.d/default.conf

# Copy your custom configuration file
COPY nginx.conf /etc/nginx/conf.d/

# Copy your static HTML website files to the Nginx root directory
COPY index.html /usr/share/nginx/html/

# Expose HTTP port 80
EXPOSE 80

# Nginx starts automatically in the base image, no CMD needed

