require 'rspec'
require 'async'
require 'kubetruth/ctapi'

module Kubetruth

  describe CtApi, :vcr => {
      # uncomment (or delete vcr yml file) to force record of new fixtures
      # :record => :all
  } do

    let(:ctapi) {
      # Spin up a local dev server and create a user with an api key to use
      # here, or use cloudtruth actual
      key = ENV['CLOUDTRUTH_API_KEY']
      url = ENV['CLOUDTRUTH_API_URL'] || "https://localhost:8000"
      instance = ::Kubetruth::CtApi.new(api_key: key, api_url: url)
      instance.client.config.debugging = false # ssl debug logging is messy, so only turn this on as desired
      instance.client.config.ssl_verify = false
      instance
    }

    describe "instance" do

      it "fails if not configured" do
        expect { described_class.instance }.to raise_error(ArgumentError, /has not been configured/)
      end

      it "succeeds when configured" do
        described_class.configure(api_key: "sekret", api_url: "http://localhost")
        expect(described_class.instance).to be_an_instance_of(described_class)
        expect(described_class.instance).to equal(described_class.instance)
        expect(described_class.instance.instance_variable_get(:@api_key)).to eq("sekret")
        expect(described_class.instance.instance_variable_get(:@api_url)).to eq("http://localhost")
      end

      it "re-instantiates when reset" do
        described_class.configure(api_key: "sekret", api_url: "http://localhost")
        old = described_class.instance
        described_class.reset
        expect(old).to_not equal(described_class.instance)
      end

    end

    describe "#environments" do

      it "gets environments" do
        expect(ctapi.environments).to match hash_including("default")
        expect(ctapi.environment_names).to match array_including("default")
      end

      it "memoizes environments" do
        expect(ctapi.environments).to equal(ctapi.environments)
        expect(ctapi.environment_names).to eq(ctapi.environment_names) # Hash#keys creates new object
      end

    end

    describe "#environment_id" do

      it "gets id" do
        expect(ctapi.environments).to match hash_including("default")
        expect(ctapi.environment_id("default")).to be_present
        expect(Logging.contents).to_not match(/Unknown environment, retrying/)
      end

      it "raises if environment doesn't exist" do
        expect { ctapi.environment_id("badenv") }.to raise_error(Kubetruth::Error, /Unknown environment/)
      end

    end

    describe "#projects" do

      it "gets projects" do
        expect(ctapi.projects).to match hash_including("MyFirstProject")
        expect(ctapi.project_names).to match array_including("MyFirstProject")
      end

      it "memoizes projects " do
        expect(ctapi.projects).to equal(ctapi.projects)
        expect(ctapi.project_names).to eq(ctapi.project_names) # Hash#keys creates new object
      end

    end

    describe "#project_id" do

      it "gets id" do
        expect(ctapi.projects).to match hash_including("MyFirstProject")
        expect(ctapi.project_id("MyFirstProject")).to be_present
        expect(Logging.contents).to_not match(/Unknown project, retrying/)
      end

      it "raises if project doesn't exist" do
        expect { ctapi.project_id("nothere") }.to raise_error(Kubetruth::Error, /Unknown project/)
      end

    end


    describe "#parameters" do

      before(:each) do
        @project_name = "TestProject"
        existing = ctapi.apis[:projects].projects_list.results
        existing.each do |proj|
          if  proj.name == @project_name
            ctapi.apis[:projects].projects_destroy(proj.id)
          end
        end

        ctapi.apis[:projects].projects_create(CloudtruthClient::ProjectCreate.new(name: @project_name))
        @project_id = ctapi.projects[@project_name]
        @one_param = ctapi.apis[:projects].projects_parameters_create(@project_id, CloudtruthClient::ParameterCreate.new(name: "one"))
        @two_param = ctapi.apis[:projects].projects_parameters_create(@project_id, CloudtruthClient::ParameterCreate.new(name: "two"))
      end

      it "gets parameters" do
        params = ctapi.parameters(project: @project_name)
        expect(params).to match array_including(Parameter)
        expect(params.collect(&:key)).to eq(["one", "two"])
      end

      it "doesn't expose secret in debug log" do
        three_param = ctapi.apis[:projects].projects_parameters_create(@project_id, CloudtruthClient::ParameterCreate.new(name: "three", secret: true))
        ctapi.apis[:projects].projects_parameters_values_create(three_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("default"), dynamic: false, static_value: "defaultthree"))
        params = ctapi.parameters(project: @project_name)
        secrets = params.find {|p| p.secret }
        expect(secrets.size).to_not eq(0)
        expect(Logging.contents).to include("<masked>")
        expect(Logging.contents).to_not include("defaultthree")
      end

      it "uses environment to get values" do
        ctapi.apis[:projects].projects_parameters_values_create(@one_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("default"), dynamic: false, static_value: "defaultone"))
        ctapi.apis[:projects].projects_parameters_values_create(@one_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("development"), dynamic: false, static_value: "developmentone"))
        ctapi.apis[:projects].projects_parameters_values_create(@two_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("default"), dynamic: false, static_value: "defaulttwo"))
        ctapi.apis[:projects].projects_parameters_values_create(@two_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("development"), dynamic: false, static_value: "developmenttwo"))

        params = ctapi.parameters(project: @project_name, environment: "default")
        expect(params.collect(&:value)).to eq(["defaultone", "defaulttwo"])
        params = ctapi.parameters(project: @project_name, environment: "development")
        expect(params.collect(&:value)).to eq(["developmentone", "developmenttwo"])
      end

    end

    describe "#templates" do

      before(:each) do
        @project_name = "TestProject"
        existing = ctapi.apis[:projects].projects_list.results
        existing.each do |proj|
          if  proj.name == @project_name
            ctapi.apis[:projects].projects_destroy(proj.id)
          end
        end

        ctapi.apis[:projects].projects_create(CloudtruthClient::ProjectCreate.new(name: @project_name))
        @project_id = ctapi.projects[@project_name]
        @one_param = ctapi.apis[:projects].projects_parameters_create(@project_id, CloudtruthClient::ParameterCreate.new(name: "one"))
        @two_param = ctapi.apis[:projects].projects_parameters_create(@project_id, CloudtruthClient::ParameterCreate.new(name: "two", secret: true))
        @one_tmpl = ctapi.apis[:projects].projects_templates_create(@project_id, CloudtruthClient::TemplateCreate.new(name: "one", body: "tmpl1 {{one}}"))
        @two_tmpl = ctapi.apis[:projects].projects_templates_create(@project_id, CloudtruthClient::TemplateCreate.new(name: "two", body: "tmpl2 {{two}}"))
      end

      it "gets templates" do
        templates = ctapi.templates(project: @project_name)
        expect(templates).to match hash_including("one", "two")
        expect(ctapi.template_names(project: @project_name)).to eq(["one", "two"])
      end

      it "memoizes templates " do
        expect(ctapi.templates(project: @project_name)).to equal(ctapi.templates(project: @project_name))
        expect(ctapi.template_names(project: @project_name)).to eq(ctapi.template_names(project: @project_name)) # Hash#keys creates new object
      end

      describe "#template_id" do

        it "gets id" do
          expect(ctapi.template_id("one", project: @project_name)).to be_present
          expect(Logging.contents).to_not match(/Unknown template, retrying/)
        end

        it "raises if template doesn't exist" do
          expect { ctapi.template_id("nothere", project: @project_name  ) }.to raise_error(Kubetruth::Error, /Unknown template/)
        end

      end

      describe "#template" do

        it "gets template" do
          ctapi.apis[:projects].projects_parameters_values_create(@one_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("default"), dynamic: false, static_value: "defaultone"))
          expect(ctapi.template("one", project: @project_name, environment: "default")).to eq("tmpl1 defaultone")
          expect(Logging.contents).to match(/Template Retrieve query result.*tmpl1 defaultone/)
        end

        it "masks secrets in log for templates that reference them" do
          ctapi.apis[:projects].projects_parameters_values_create(@two_param.id, @project_id, CloudtruthClient::ValueCreate.new(environment: ctapi.environment_id("default"), dynamic: false, static_value: "defaulttwo"))
          expect(ctapi.template("two", project: @project_name, environment: "default")).to eq("tmpl2 defaulttwo")
          expect(Logging.contents).to_not match(/Template Retrieve query result.*tmpl2 defaulttwo/)
          expect(Logging.contents).to match(/Template Retrieve query result.*<masked>/)
        end

      end

    end

    describe "validate async" do

      it "does api requests concurrently" do
        start_times = {}
        end_times = {}
        start_times[:total] = Time.now.to_f

        Async(annotation: "top") do

          Async(annotation: "first") do
            start_times[:first] = Time.now.to_f
            ctapi.projects # non-memoized
            end_times[:first] = Time.now.to_f
          end

          Async(annotation: "second") do
            start_times[:second] = Time.now.to_f
            ctapi.projects # non-memoized
            end_times[:second] = Time.now.to_f
          end

        end

        end_times[:total] = Time.now.to_f
        elapsed_times = Hash[end_times.collect {|k, v| [k, v - start_times[k]]}]

        logger.debug { "Start times: #{start_times.inspect}" }
        logger.debug { "End times: #{end_times.inspect}" }
        logger.debug { "Elapsed times: #{elapsed_times.inspect}" }

        # When VCR plays back requests, it doesn't use concurrent IO like live
        # requests do, so this assertion will fail.  As a result we only do the
        # check when someone has cleared the cassette and is re-running against
        # an actual http api
        if VCR.current_cassette.originally_recorded_at.nil? || VCR.current_cassette.record_mode == :all
          expect(elapsed_times[:total]).to be < (elapsed_times[:first] + elapsed_times[:second])
        end

      end

    end


  end

end
