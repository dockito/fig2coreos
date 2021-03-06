require 'yaml'
require 'fileutils'

class Fig2CoreOS
  def self.convert(app_name, fig_file, output_dir, options={})
    Fig2CoreOS.new(app_name, fig_file, output_dir, options)
  end

  def initialize(app_name, fig_file, output_dir, options={})
    @app_name = app_name
    @fig = YAML.load_file(fig_file.to_s)
    @output_dir = File.expand_path(output_dir.to_s)
    @vagrant = (options[:type] == "vagrant")

    # clean and setup directory structure
    FileUtils.rm_rf(Dir[File.join(@output_dir, "*.service")])
    FileUtils.rm_rf(File.join(@output_dir, "media"))
    FileUtils.rm_rf(File.join(@output_dir, "setup-coreos.sh"))
    FileUtils.rm_rf(File.join(@output_dir, "Vagrantfile"))

    if @vagrant
        FileUtils.mkdir_p(File.join(@output_dir, "media", "state", "units"))
        create_vagrant_file
    end

    create_service_files
    exit 0
  end

  def create_service_files
  	@fig.each do |service_name, service|
      service_name ="#{@app_name}-#{service_name}"
      image = service["image"]
      ports = (service["ports"] || []).map{|port| "-p #{port}"}
      volumes = (service["volumes"] || []).map{|volume| "-v #{volume}"}
      privileged = service["privileged"]
      command = service["command"] || ""

      links = (service["links"] || []).map do |link|
        container_name = link.split(":")[0]
        container_alias = link.split(":")[1] || "#{container_name}_1"

        "--link #{@app_name}-#{container_name}_1:#{container_alias}"
      end

      envs_directives = (service["environment"] || []).map do |env_name, env_value|
        "Environment=\"#{env_name}=#{env_value}\""
      end

      envs_run_parameters = (service["environment"] || []).map do |env_name, env_value|
        "-e #{env_name}"
      end

      after = if service["links"]
        container_name = service["links"].last.split(":")[0]

        "#{@app_name}-#{container_name}.1"
      else
        "docker"
      end

      if @vagrant
        base_path = File.join(@output_dir, "media", "state", "units")
      else
        base_path = @output_dir
      end

      File.open(File.join(base_path, "#{service_name}.1.service") , "w") do |file|
        file << <<-eof
[Unit]
Description=Run #{service_name}_1
After=#{after}.service
Requires=#{after}.service

[Service]
KillMode=none
TimeoutStartSec=0
User=core
Restart=always
RestartSec=10s
#{envs_directives.join("\n")}
ExecStartPre=-/usr/bin/docker kill #{service_name}_1
ExecStartPre=-/usr/bin/docker rm #{service_name}_1
ExecStartPre=/usr/bin/docker pull #{image}
ExecStart=/usr/bin/docker run #{privileged && "--privileged=true"} --rm --name #{service_name}_1 #{volumes.join(" ")} #{links.join(" ")} #{envs_run_parameters.join(" ")} #{ports.join(" ")} #{image} #{command}
ExecStop=/usr/bin/docker kill #{service_name}_1
ExecStopPost=/usr/bin/docker rm #{service_name}_1

[Install]
WantedBy=multi-user.target
eof
      end

    end
  end

  def create_vagrant_file
    File.open(File.join(@output_dir, "setup-coreos.sh"), "w") do |file|
      file << <<-eof
# Switch to root for setting up systemd
sudo -i

# Clear old containers
systemctl stop local-enable.service
systemctl stop etcd-cluster.service
/usr/bin/docker ps -a -q | xargs docker kill
/usr/bin/docker ps -a -q | xargs docker rm

# Copy the services into place
eof
      @fig.each do |service_name, service|
        file << "cp " + File.join("share", "media", "state", "units", "#{service_name}.1.service") + " /media/state/units/#{service_name}.1.service\n"
      end

      file << <<-eof

# Fix etcd-cluster setup
HOSTNAME=$(</proc/sys/kernel/hostname)

if [ ! -d /var/run/etcd/${HOSTNAME} ]
then
  mkdir /var/run/etcd/${HOSTNAME}
  chown core:core /var/run/etcd/${HOSTNAME}
fi

echo 192.168.10.2 > /var/run/etcd/MY_IP

# Replace the existing line:
sed -i -e "s@ExecStart=.*@ExecStart=/usr/bin/etcd -s 192.168.10.2:7001 -sl 0.0.0.0 -cl 0.0.0.0 -c 192.168.10.2:4001 ${CLUSTER_OPT} -d /var/run/etcd/${HOSTNAME} -n $HOSTNAME@" /media/state/units/etcd-cluster.service

# Start containers and fleet
systemctl daemon-reload
systemctl start etcd-cluster.service
systemctl start local-enable.service
systemctl start fleet

etcdctl mkdir /services
eof
      @fig.each do |service_name, service|
        file << "etcdctl mkdir /services/#{service_name}\n"
      end
      file << "cd /media/state/units; for service in *.service; do fleetctl start $service; done\n"
      file << "sleep 3; /usr/bin/docker ps -a -q | xargs docker rm\n"
      file << "sleep 3; /usr/bin/docker ps -a -q | xargs docker rm\n"
      file << "echo 'SUCCESS'\n"
      file << "exit 0\n"

      file.chmod(0755)
    end

    File.open(File.join(@output_dir, "Vagrantfile"), "w") do |file|
      file << <<-eof
# -*- mode: ruby -*-
# vi: set ft=ruby :

$expose_port = 8080

Vagrant.configure("2") do |config|
  config.vm.box = "coreos"
  config.vm.box_url = "http://storage.core-os.net/coreos/amd64-generic/dev-channel/coreos_production_vagrant.box"
  config.vm.hostname = "coreos-#{@app_name}"

  config.vm.provider :virtualbox do |vb, override|
    vb.name = "vagrant-coreos-docker-converted-from-fig-#{@app_name}"
    # Fix docker not being able to resolve private registry in VirtualBox
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end

  # Share this folder so provisioner can access Dockerfile an apache.service
  # This is from coreos/coreos-vagrant, but won't work on Windows hosts
  config.vm.network "private_network", ip: "192.168.10.2"
  config.vm.synced_folder ".", "/home/core/share", id: "core", :nfs => true,  :mount_options   => ['nolock,vers=3,udp']

  # Forward port 80 from coreos (which is forwarding port 80 of the container)
  config.vm.network :forwarded_port, guest: 80, host: $expose_port, host_ip: "127.0.0.1"

  config.vm.provider :vmware_fusion do |vb, override|
    override.vm.box_url = "http://storage.core-os.net/coreos/amd64-generic/dev-channel/coreos_production_vagrant_vmware_fusion.box"
  end

  # plugin conflict
  if Vagrant.has_plugin?("vagrant-vbguest") then
    config.vbguest.auto_update = false
  end

  # Provision
  config.vm.provision "shell", :path => "setup-coreos.sh"
end
eof
    end

    if File.directory?(File.join(@output_dir, ".vagrant"))
      puts "[SUCCESS] Try this: cd #{@output_dir} && vagrant reload --provision"
    else
      puts "[SUCCESS] Try this: cd #{@output_dir} && vagrant up"
    end
  end
end
