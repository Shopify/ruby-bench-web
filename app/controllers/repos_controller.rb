class ReposController < ApplicationController
  before_action :find_organization_by_name
  before_action :find_organization_repo_by_name

  def index
    @charts =
      if charts = $redis.get("sparklines:#{@repo.id}")
        JSON.parse(charts).with_indifferent_access
      else
        @repo.generate_sparkline_data
      end
  end

  def show
    display_count = params[:display_count].to_i

    @benchmark_run_display_count =
      if BenchmarkRun::PAGINATE_COUNT.include?(display_count)
        display_count
      else
        BenchmarkRun::DEFAULT_PAGINATE_COUNT
      end

    if (@form_result_type = params[:result_type]) &&
       (@benchmark_type = find_benchmark_type_by_category(@form_result_type))

      @charts = @benchmark_type.benchmark_result_types.map do |benchmark_result_type|
        cache_key = "#{BenchmarkRun.charts_cache_key(@benchmark_type, benchmark_result_type)}:#{@benchmark_run_display_count}"
        cache_key_ruby_v = "#{cache_key}_ruby_v"

        if (columns = $redis.get(cache_key))
          # read the cached @ruby_versions separately
          @ruby_versions = JSON.parse($redis.get(cache_key_ruby_v))
          [JSON.parse(columns).symbolize_keys!, benchmark_result_type]
        else
          # save the ruby versions
          @ruby_versions = []

          benchmark_runs = BenchmarkRun.fetch_commit_benchmark_runs(
            @form_result_type, benchmark_result_type, @benchmark_run_display_count
          )

          next if benchmark_runs.empty?

          chart_builder = ChartBuilder.new(benchmark_runs.sort_by do |benchmark_run|
            benchmark_run.initiator.created_at
          end)

          columns = chart_builder.build_columns do |benchmark_run|
            environment = YAML.load(benchmark_run.environment)

            commit = benchmark_run.initiator

            # generate the ruby_version object
            config = {
              commit: commit.sha1[0..6],
              commit_date: commit.created_at,
              commit_message: commit.message.truncate(30)
            }
            if environment.is_a?(Hash)
              config.merge!(environment)
              # solely for the purpose of generating the correct HTML
              environment = hash_to_html(environment)
            else
              config.merge!(environment: environment)
            end

            @ruby_versions << config

            # generate HTML
            "Commit: #{config[:commit]}<br>" \
            "Commit Date: #{config[:commit_date]}<br>" \
            "Commit Message: #{config[:commit_message]}<br>" \
            "#{environment}"
          end

          $redis.set(cache_key, columns.to_json)
          # cache the `@ruby_versions` as well
          $redis.set(cache_key_ruby_v, @ruby_versions.to_json)
          [columns, benchmark_result_type]
        end
      end.compact
    end

    respond_to do |format|
      format.html do
        @result_types = fetch_categories
      end

      format.json { render :json => generate_json(:commits) }

      format.js
    end
  end

  def show_releases
    if (@form_result_type = params[:result_type]) &&
       (@benchmark_type = find_benchmark_type_by_category(@form_result_type))

      @charts = @benchmark_type.benchmark_result_types.map do |benchmark_result_type|
        # save the ruby versions
        @ruby_versions = []

        benchmark_runs = BenchmarkRun.fetch_release_benchmark_runs(
          @form_result_type, benchmark_result_type
        )

        next if benchmark_runs.empty?
        benchmark_runs = BenchmarkRun.sort_by_initiator_version(benchmark_runs)

        if latest_benchmark_run = BenchmarkRun.latest_commit_benchmark_run(@benchmark_type, benchmark_result_type)
          benchmark_runs << latest_benchmark_run
        end

        columns = ChartBuilder.new(benchmark_runs).build_columns do |benchmark_run|
          environment = YAML.load(benchmark_run.environment)

          # generate the ruby_version object
          config = {version: benchmark_run.initiator.version}
          if environment.is_a?(Hash)
            config.merge!(environment)
            # solely for the purpose of generating the correct HTML
            environment = hash_to_html(environment)
          else
            config.merge!(environment: environment)
          end

          @ruby_versions << config

          # generate HTML
          "Version: #{config[:version]}<br>" \
          "#{environment}"
        end

        [columns, benchmark_result_type]
      end.compact
    end

    respond_to do |format|
      format.html do
        @result_types = fetch_categories
      end

      format.json { render :json => generate_json(:releases) }

      format.js
    end
  end

  private

  def find_organization_by_name
    @organization = Organization.find_by_name(params[:organization_name]) || not_found
  end

  def find_organization_repo_by_name
    @repo = @organization.repos.find_by_name(params[:repo_name]) || not_found
  end

  def find_benchmark_type_by_category(category)
    @repo.benchmark_types.find_by_category(category)
  end

  def fetch_categories
    @repo.benchmark_types.pluck(:category)
  end

  # @param context indicates if we are calling from a 'releases' or 'commits' context
  def generate_json(context)
    @charts.map do |chart|
      # rename for clarity
      result_data = chart[0]
      result_type = chart[1]

      datapoints = []
      variations = []
      JSON.parse(result_data[:columns]).each do |column| 
        # get the data (sometimes there's two sets of data for one chart)
        datapoints << column['data'] 
        # this is for when there are two data sets in one chart (ex. rails commits benchmarks)
        # then the variations will be `with_prepared_statements` and `without_prepared_statements`
        variations << column['name']
      end

      # generate the json
      config = {
        benchmark_name: params[:result_type],
        datapoints: datapoints,
        ruby_versions: @ruby_versions,
        measurement: result_type[:name],
        unit: result_type[:unit]
      }
      config[:variations] = variations if variations.length > 1
      config
    end
  end

  def hash_to_html(hash)
    hash.map do |k, v|
      "#{k}: #{v}" 
    end.join("<br>")
  end
end
