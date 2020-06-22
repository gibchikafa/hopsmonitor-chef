require 'resolv'

crypto_dir = x509_helper.get_crypto_dir(node['hopsmonitor']['user'])
kagent_hopsify "Generate x.509" do
  user node['hopsmonitor']['user']
  crypto_directory crypto_dir
  action :generate_x509
  not_if { conda_helpers.is_upgrade || node["kagent"]["test"] == true }
end

#
# Prometheus installation
# 

base_package_filename = File.basename(node['prometheus']['url'])
cached_package_filename = "#{Chef::Config['file_cache_path']}/#{base_package_filename}"

remote_file cached_package_filename do
  source node['prometheus']['url']
  owner "root"
  mode "0644"
  action :create_if_missing
end

directory node['prometheus']['root_dir'] do
  owner node['hopsmonitor']['user']
  group node['hopsmonitor']['group']
  mode '0750'
  action :create
end

prometheus_downloaded= "#{node['prometheus']['home']}/.prometheus.extracted_#{node['prometheus']['version']}"
# Extract prometheus 
bash 'extract_prometheus' do
  user "root"
  code <<-EOH
    tar -xf #{cached_package_filename} -C #{node['prometheus']['root_dir']}
    chown -R #{node['hopsmonitor']['user']}:#{node['hopsmonitor']['group']} #{node['prometheus']['home']}
    chmod -R 750 #{node['prometheus']['home']}
    touch #{prometheus_downloaded}
    chown #{node['hopsmonitor']['user']} #{prometheus_downloaded}
  EOH
  not_if { ::File.exists?( prometheus_downloaded ) }
end

link node['prometheus']['base_dir'] do
  owner node['hopsmonitor']['user']
  group node['hopsmonitor']['group']
  to node['prometheus']['home']
end

certificate = "#{crypto_dir}/#{x509_helper.get_certificate_bundle_name(node['hopsmonitor']['user'])}"
key = "#{crypto_dir}/#{x509_helper.get_private_key_pkcs8_name(node['hopsmonitor']['user'])}"
hops_ca = "#{crypto_dir}/#{x509_helper.get_hops_ca_bundle_name()}"
template "#{node['prometheus']['base_dir']}/prometheus.yml" do
  source "prometheus.yml.erb" 
  owner node['hopsmonitor']['user']
  group node['hopsmonitor']['group']
  mode '0700'
  action :create
  variables({
      'alertmanagers' => consul_helper.get_service_fqdn("alertmanager.prometheus") + ":" + node['alertmanager']['port'],
      'certificate' => certificate,
      'key' => key,
      'hops_ca' => hops_ca
  })
end

directory node['prometheus']['rules_dir'] do 
  action :delete
  recursive true 
end

remote_directory node['prometheus']['rules_dir'] do 
  source "rules"
  owner node['hopsmonitor']['user']
  group node['hopsmonitor']['group']
  mode 0700
  files_owner node['hopsmonitor']['user']
  files_group node['hopsmonitor']['group']
  files_mode 0700
end

case node['platform_family']
when "rhel"
  systemd_script = "/usr/lib/systemd/system/prometheus.service" 
else
  systemd_script = "/lib/systemd/system/prometheus.service"
end

service "prometheus" do
  provider Chef::Provider::Service::Systemd
  supports :restart => true, :stop => true, :start => true, :status => true
  action :nothing
end

template systemd_script do
  source "prometheus.service.erb"
  owner "root"
  group "root"
  mode 0664
  if node['services']['enabled'] == "true"
    notifies :enable, "service[prometheus]"
  end
  notifies :restart, "service[prometheus]"
end

kagent_config "prometheus" do
  action :systemd_reload
end

if node['kagent']['enabled'] == "true"
   kagent_config "prometheus" do
     service "Monitoring"
     restart_agent false 
   end
end

if service_discovery_enabled()
  # Register Prometheus with Consul
  consul_service "Registering Prometheus with Consul" do
    service_definition "prometheus-consul.hcl.erb"
    action :register
  end
end 
