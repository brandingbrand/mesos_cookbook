#
# Cookbook Name:: mesos
# Recipe:: install
#
# Copyright (C) 2015 Medidata Solutions, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe 'java'

#
# Install default repos
#

include_recipe 'mesos::repo' if node['mesos']['repo']

#
# Install package
#

case node['platform_family']
when 'debian'
  %w(unzip default-jre-headless libcurl4 libcurl4-openssl-dev libsvn1).each do |pkg|
    package pkg do
      action :install
    end
  end

  # libcurl3/4 shenanigans
  # https://bugs.launchpad.net/ubuntu/+source/curl/+bug/1754294/comments/55
  # remote_file "#{Chef::Config[:file_cache_path]}/mesos.deb" do
  remote_file "/data/mesos.deb" do
    source "http://repos.mesosphere.com/debian/pool/main/m/mesos/mesos_#{node['mesos']['version']}-2.0.6.debian9_amd64.deb"
    action :create
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  directory "/data/tmp" do
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  execute 'unpack mesos deb' do
    # command "dpkg-deb -R #{Chef::Config[:file_cache_path]}/mesos.deb #{Chef::Config[:file_cache_path]}/tmp"
    command "dpkg-deb -R /data/mesos.deb /data/tmp"
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  ruby_block 'update control file' do
    block do
      # fe = Chef::Util::FileEdit.new("#{Chef::Config[:file_cache_path]}/tmp/DEBIAN/control")
      fe = Chef::Util::FileEdit.new("/data/tmp/DEBIAN/control")
      fe.search_file_replace('libcurl3', 'libcurl3|libcurl4')
      fe.write_file
    end
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  execute 'save new deb' do
    command "dpkg-deb -b /data/tmp #{Chef::Config[:file_cache_path]}/mesos.deb"
    # command "dpkg-deb -b /data/tmp #{Chef::Config[:file_cache_path]}/mesos.deb"
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  directory '/data/tmp' do
    action :delete
    recursive true
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end

  dpkg_package 'mesos' do
    source "#{Chef::Config[:file_cache_path]}/mesos.deb"
    not_if { ::File.exists? '/usr/sbin/mesos-master' }
  end
when 'rhel'
  %w(unzip libcurl subversion).each do |pkg|
    yum_package pkg do
      action :install
    end
  end

  yum_package 'mesos' do
    version lazy {
      # get the version-release string directly from the Yum provider rpmdb
      Chef::Provider::Package::Yum::YumCache
        .instance.instance_variable_get('@rpmdb').lookup('mesos')
        .find { |pkg| pkg.version.v == node['mesos']['version'] }
        .version.to_s
    }
  end
end

# libcurl3 shenanigans
# https://dev.to/jake/using-libcurl3-and-libcurl4-on-ubuntu-1804-bionic-184g
directory '/data/libcurl3' do
  owner '_apt'
  group 'root'
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

execute 'download libcurl3' do
  cwd '/data/libcurl3'
  command 'apt-get download -o=dir::cache=/data/libcurl3 libcurl3'
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

execute 'ar' do
  cwd '/data/libcurl3'
  command 'ar x libcurl3* data.tar.xz'
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

execute 'tar' do
  cwd '/data/libcurl3'
  command 'tar xf data.tar.xz'
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

file '/usr/lib/libcurl.so.3' do
  action :delete
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

execute 'copy file' do
  command 'cp -L /data/libcurl3/usr/lib/x86_64-linux-gnu/libcurl.so.4 /usr/lib/libcurl.so.3'
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

directory '/data/libcurl3' do
  action :delete
  recursive true
  not_if { ::File.exist?('/usr/lib/libcurl.so.3') }
end

#
# Support for multiple init systems
#

directory '/etc/mesos-chef'

# Init templates
template 'mesos-master-init' do
  case node['mesos']['init']
  when 'systemd'
    path '/etc/systemd/system/mesos-master.service'
    source 'systemd.erb'
  when 'sysvinit_debian'
    mode 0o755
    path '/etc/init.d/mesos-master'
    source 'sysvinit_debian.erb'
  when 'upstart'
    path '/etc/init/mesos-master.conf'
    source 'upstart.erb'
  end
  variables(name:    'mesos-master',
            wrapper: '/etc/mesos-chef/mesos-master')
end

template 'mesos-slave-init' do
  case node['mesos']['init']
  when 'systemd'
    path '/etc/systemd/system/mesos-slave.service'
    source 'systemd.erb'
  when 'sysvinit_debian'
    mode 0o755
    path '/etc/init.d/mesos-slave'
    source 'sysvinit_debian.erb'
  when 'upstart'
    path '/etc/init/mesos-slave.conf'
    source 'upstart.erb'
  end
  variables(name:    'mesos-slave',
            wrapper: '/etc/mesos-chef/mesos-slave')
end

# Reload systemd on template change
execute 'systemctl-daemon-reload' do
  command '/bin/systemctl --system daemon-reload'
  subscribes :run, 'template[mesos-master-init]'
  subscribes :run, 'template[mesos-slave-init]'
  action :nothing
  only_if { node['mesos']['init'] == 'systemd' }
end

# Disable services by default
service 'mesos-master-default' do
  service_name 'mesos-master'
  case node['mesos']['init']
  when 'systemd'
    provider Chef::Provider::Service::Systemd
  when 'sysvinit_debian'
    provider Chef::Provider::Service::Init::Debian
  when 'upstart'
    provider Chef::Provider::Service::Upstart
  end
  action [:stop, :disable]
  not_if { node['recipes'].include?('mesos::master') }
end

service 'mesos-slave-default' do
  service_name 'mesos-slave'
  case node['mesos']['init']
  when 'systemd'
    provider Chef::Provider::Service::Systemd
  when 'sysvinit_debian'
    provider Chef::Provider::Service::Init::Debian
  when 'upstart'
    provider Chef::Provider::Service::Upstart
  end
  action [:stop, :disable]
  not_if { node['recipes'].include?('mesos::slave') }
end
