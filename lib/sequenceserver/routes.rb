require 'json'
require 'tilt/erb'
require 'sinatra/base'
require 'rest-client'

require 'sequenceserver/job'
require 'sequenceserver/blast'
require 'sequenceserver/blast/tasks'
require 'sequenceserver/report'
require 'sequenceserver/database'
require 'sequenceserver/sequence'
require 'rack/csrf'

module SequenceServer
  # Controller.
  class Routes < Sinatra::Base
    # See
    # http://www.sinatrarb.com/configuration.html
    configure do
      # We don't need Rack::MethodOverride. Let's avoid the overhead.
      disable :method_override

      # Ensure exceptions never leak out of the app. Exceptions raised within
      # the app must be handled by the app.
      disable :show_exceptions, :raise_errors

      # Make it a policy to dump to 'rack.errors' any exception raised by the
      # app.
      enable :dump_errors

      # We don't want Sinatra do setup any loggers for us. We will use our own.
      set :logging, nil

      # Override in config.ru if the instance is served under a subpath
      # e.g. for example.org/our-sequenceserver set to '/our-sequenceserver'
      set :root_path_prefix, ''

      set :layout, :'layout'
    end

    # See
    # http://www.sinatrarb.com/intro.html#Mime%20Types
    configure do
      mime_type :fasta, 'text/fasta'
      mime_type :xml,   'text/xml'
      mime_type :tsv,   'text/tsv'
    end

    configure do
      # Public, and views directory will be found here.
      set :root, File.join(__dir__, '..', '..')

      # Allow :frame_options to be configured for Rack::Protection.
      #
      # By default _any website_ can embed SequenceServer in an iframe. To
      # change this, set `:frame_options` config to :deny, :sameorigin, or
      # 'ALLOW-FROM uri'.
      set :protection, lambda {
        frame_options = SequenceServer.config[:frame_options]
        frame_options && { frame_options: frame_options }
      }

      use(
        Rack::Session::Cookie,
        key: 'rack.session.sequenceserver',
        secret: ENV.fetch('SESSION_SECRET') { SecureRandom.alphanumeric(64) }
      )

      # CSRF protection for all POSTs except those explicitly skipped.
      # Upload endpoint accepts CSRF tokens from the page meta tag; we also
      # allow skipping in test/dev via SKIP_CSRF_PROTECTION.
      use Rack::Csrf, raise: true, skip: ['POST:/cloud_share', 'POST:/upload', 'POST:/databases/rename', 'POST:/databases/delete'] unless ENV['SKIP_CSRF_PROTECTION'] == 'true'
    end

    unless ENV['SEQUENCE_SERVER_COMPRESS_RESPONSES'] == 'false'
      # Serve compressed responses.
      use Rack::Deflater
    end

    # For any request that hits the app,  log incoming params at debug level.
    before do
      logger.debug params
    end

    # Set JSON content type for JSON endpoints.
    before '*.json' do
      content_type 'application/json'
    end

    # Returns base HTML. Rest happens client-side: rendering the search form.
    get '/' do
      erb :search, layout: settings.layout
    end

    # Returns data that is used to render the search form client side. These
    # include available databases and user-defined search options.
    get '/searchdata.json' do
      # Always compute databases fresh from disk to reflect latest changes.
      current_dbs = SequenceServer::MAKEBLASTDB.new(SequenceServer.config[:database_dir]).formatted_fastas
      searchdata = {
        query: Database.retrieve(params[:query]),
        database: current_dbs,
        options: SequenceServer.config[:options],
        blastTaskMap: SequenceServer::BLAST::Tasks.to_h
      }

      searchdata.update(tree: Database.tree) if SequenceServer.config[:databases_widget] == 'tree'

      # If a job_id is specified, update searchdata from job meta data (i.e.,
      # query, pre-selected databases, advanced options used). Query is only
      # updated if params[:query] is not specified.
      update_searchdata_from_job(searchdata) if params[:job_id]

      searchdata.to_json
    end

    # Upload a FASTA file and create a BLAST database from it.
    # Parameters:
    # - file: multipart file upload (required)
    # - title: optional database title
    # Returns JSON with status and db info or redirects to '/'.
    post '/upload' do
      begin
        halt 415, { error: 'No file uploaded' }.to_json unless params[:file]

        uploaded = params[:file]
        tmpfile = uploaded[:tempfile]
        filename = uploaded[:filename].to_s
        halt 415, { error: 'Empty filename' }.to_json if filename.empty?

        # Basic filename sanitization and ensure .fa/.fasta-like extension
        safe_name = filename.gsub(/[^A-Za-z0-9._-]/, '_')
        safe_name = 'upload.fasta' if safe_name.empty?

        dbdir = SequenceServer.config[:database_dir]
        halt 500, { error: 'Database directory not configured' }.to_json unless dbdir

        dest = File.join(dbdir, safe_name)
        # Avoid overwrite: if exists, add numeric suffix
        if File.exist?(dest)
          base = File.basename(safe_name, '.*')
          ext = File.extname(safe_name)
          i = 1
          begin
            candidate = File.join(dbdir, sprintf('%s_%d%s', base, i, ext))
            i += 1
          end while File.exist?(candidate)
          dest = candidate
        end

        # Persist the upload to database_dir
        File.open(dest, 'wb') { |f| IO.copy_stream(tmpfile, f) }

        # Quick sanity check it looks like FASTA
        first_char = File.read(dest, 1)
        unless first_char == '>'
          File.delete(dest) rescue nil
          halt 415, { error: 'Uploaded file does not look like FASTA' }.to_json
        end

        # Guess DB type (nucleotide/protein) using existing helper
        mb = SequenceServer::MAKEBLASTDB.new(dbdir)
        # Determine DB type using simple heuristic: 90%+ ACGTU => nucleotide, else protein
        letters = []
        File.foreach(dest) do |line|
          next if line.start_with?('>')
          letters << line.gsub(/[^A-Za-z]/, '')
        end
        seq = letters.join
        cleaned = seq.gsub(/[NXnx]/, '')
        # Allow explicit override via param
        dbtype = case params[:dbtype].to_s.downcase
                 when 'nucl', 'nucleotide' then 'nucleotide'
                 when 'prot', 'protein' then 'protein'
                 else nil
                 end
        if dbtype.nil? && cleaned.length >= 10
          na = cleaned.count('AaCcGgTtUu')
          dbtype = (na.to_f / cleaned.length) > 0.9 ? 'nucleotide' : 'protein'
        end
        dbtype ||= 'nucleotide' # conservative default

        # Determine title
        title = params[:title].to_s.strip
        title = mb.send(:make_db_title, dest) if title.empty?

        # Build database non-interactively
        cmd = "makeblastdb -parse_seqids -hash_index -in '#{dest}' -dbtype #{dbtype.to_s.slice(0,4)} -title '#{title}'"
        SequenceServer.sys(cmd, path: SequenceServer.config[:bin])

        # Refresh in-memory DB list using a fresh scanner instance
        fresh = SequenceServer::MAKEBLASTDB.new(dbdir).formatted_fastas
        fresh_map = {}
        fresh.each { |d| fresh_map[d.id] = d }
        begin
          coll = SequenceServer::Database.send(:collection)
          coll.clear
          coll.merge!(fresh_map)
        rescue
          SequenceServer::Database.instance_variable_set(:@collection, fresh_map)
        end

        if request.env['HTTP_ACCEPT'].to_s.include?('application/json') || request.path.end_with?('.json')
          status 201
          content_type :json
          { status: 'ok', filename: File.basename(dest), title: title, type: dbtype }.to_json
        else
          redirect to('/'), 303
        end
      rescue SequenceServer::CommandFailed => e
        status 500
        content_type :json
        { error: 'makeblastdb failed', stdout: e.stdout, stderr: e.stderr }.to_json
      rescue => e
        status 500
        content_type :json
        { error: e.message }.to_json
      end
    end

    # Rename an existing database. Supports updating title and/or base filename.
    # Params:
    # - id: Database id (required)
    # - new_title: optional, new BLAST DB title (displayed in UI)
    # - new_basename: optional, new base filename (without path). If present,
    #                 DB files will be recreated at this base; old DB files will be removed.
    post '/databases/rename' do
      content_type :json
      begin
        db = Database[params[:id]].first
        halt 404, { error: 'Database not found' }.to_json unless db

        dbdir = SequenceServer.config[:database_dir]
        halt 500, { error: 'Database directory not configured' }.to_json unless dbdir

        # Safety: ensure db.name resides under database_dir
        full = File.expand_path(db.name)
        halt 400, { error: 'Invalid database path' }.to_json unless full.start_with?(File.expand_path(dbdir) + '/')

        new_title = params[:new_title].to_s.strip
        new_basename = params[:new_basename].to_s.strip
        halt 422, { error: 'Nothing to change' }.to_json if new_title.empty? && new_basename.empty?

        # Locate FASTA: prefer file with same base (any known ext). Otherwise extract to temp.
        base = db.name
        dir = File.dirname(base)
        # Known fasta extensions
        fasta = Dir.glob("#{base}.{fa,fasta,fna,faa,fas}").first
        cleanup_tmp = false
        unless fasta && File.exist?(fasta)
          fasta = File.join(dir, "#{File.basename(base)}.rebuild.fasta")
          cmd = "blastdbcmd -entry all -db '#{base}'"
          SequenceServer.sys(cmd, stdout: fasta, path: SequenceServer.config[:bin])
          cleanup_tmp = true
        end

        # Determine output base path
        out_base = base
        if !new_basename.empty?
          safe = new_basename.gsub(/[^A-Za-z0-9._-]/, '_')
          out_base = File.join(dir, safe)
          # avoid collision
          idx = 1
          while out_base != base && (Dir.glob("#{out_base}*{n,p}*").any? || File.exist?(out_base))
            out_base = File.join(dir, sprintf('%s_%d', safe, idx))
            idx += 1
          end
        end

        # Build makeblastdb command
        dbtype = db.type.to_s
        title = new_title.empty? ? db.title : new_title
        cmd = "makeblastdb -parse_seqids -hash_index -in '#{fasta}' -dbtype #{dbtype[0,4]} -title '#{title}' -out '#{out_base}'"
        SequenceServer.sys(cmd, path: SequenceServer.config[:bin])

        # Remove temporary fasta if we created one
        File.delete(fasta) if cleanup_tmp && File.exist?(fasta)

        # If renamed base, remove old DB files
        if out_base != base
          Dir.glob("#{base}*").each do |p|
            File.delete(p) if File.file?(p)
          end
        end

        # Refresh collection
        fresh = SequenceServer::MAKEBLASTDB.new(dbdir).formatted_fastas
        fresh_map = {}
        fresh.each { |d| fresh_map[d.id] = d }
        begin
          coll = SequenceServer::Database.send(:collection)
          coll.clear
          coll.merge!(fresh_map)
        rescue
          SequenceServer::Database.instance_variable_set(:@collection, fresh_map)
        end

        status 200
        { status: 'ok', id: params[:id], new_title: title, new_base: out_base }.to_json
      rescue SequenceServer::CommandFailed => e
        status 500
        { error: 'makeblastdb failed', stdout: e.stdout, stderr: e.stderr }.to_json
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    # Delete an existing database (DB files and matching FASTA in the same dir).
    # Params:
    # - id: Database id (required)
    post '/databases/delete' do
      content_type :json
      begin
        db = Database[params[:id]].first
        halt 404, { error: 'Database not found' }.to_json unless db

        dbdir = SequenceServer.config[:database_dir]
        halt 500, { error: 'Database directory not configured' }.to_json unless dbdir

        full = File.expand_path(db.name)
        halt 400, { error: 'Invalid database path' }.to_json unless full.start_with?(File.expand_path(dbdir) + '/')

        removed = []
        Dir.glob("#{db.name}*").each do |p|
          next unless File.file?(p)
          File.delete(p) rescue nil
          removed << p
        end

        # Refresh collection
        fresh = SequenceServer::MAKEBLASTDB.new(dbdir).formatted_fastas
        fresh_map = {}
        fresh.each { |d| fresh_map[d.id] = d }
        begin
          coll = SequenceServer::Database.send(:collection)
          coll.clear
          coll.merge!(fresh_map)
        rescue
          SequenceServer::Database.instance_variable_set(:@collection, fresh_map)
        end

        status 200
        { status: 'ok', removed: removed }.to_json
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    # Queues a search job and redirects to `/:jid`.
    post '/' do
      if params[:input_sequence]
        @input_sequence = params[:input_sequence]
        erb :search, layout: settings.layout
      else
        job = Job.create(params)
        redirect to("/#{job.id}")
      end
    end

    # Returns results for the given job id in JSON format.  Returns 202 with
    # an empty body if the job hasn't finished yet.
    get '/:jid.json' do |jid|
      job = Job.fetch(jid)
      halt 404, { error: 'Job not found' }.to_json if job.nil?
      halt 202 unless job.done?

      report = BLAST::Report.new(job)
      halt 202 unless report.done?

      if display_large_result_warning?(report.xml_file_size)
        halt 200, large_result_warning_payload(jid).to_json
      end

      report.to_json
    end

    # Returns base HTML. Rest happens client-side: polling for and rendering
    # the results.
    get '/:jid' do |jid|
      job = Job.fetch(jid)
      halt 404, File.read(File.join(settings.root, 'public/404.html')) if job.nil?

      erb :report, layout: settings.layout
    end
    # @params sequence_ids: whitespace separated list of sequence ids to
    # retrieve
    # @params database_ids: whitespace separated list of database ids to
    # retrieve the sequence from.
    # @params download: whether to return raw response or initiate file
    # download
    #
    # Use whitespace to separate entries in sequence_ids (all other chars exist
    # in identifiers) and retreival_databases (we don't allow whitespace in a
    # database's name, so it's safe).
    get '/get_sequence/' do
      sequence_ids = params[:sequence_ids].to_s.split(',').uniq
      database_ids = params[:database_ids].to_s.split(',')
      if sequence_ids.empty?
        status 422
        return { error: 'No sequence ids provided' }.to_json
      end

      if database_ids.empty?
        status 422
        return { error: 'No database ids provided' }.to_json
      end
      sequences = Sequence::Retriever.new(sequence_ids, database_ids)
      sequences.to_json
    end

    post '/get_sequence' do
      sequence_ids = params['sequence_ids'].to_s.split(',').uniq
      database_ids = params['database_ids'].to_s.split(',')

      if sequence_ids.empty?
        status 422
        return 'No sequence ids provided'
      end

      if database_ids.empty?
        status 422
        return 'No database ids provided'
      end

      sequences = Sequence::Retriever.new(sequence_ids, database_ids, true)
      send_file(sequences.file.path,
                type: sequences.mime,
                filename: sequences.filename)
    end

    # Download BLAST report in various formats.
    get '/download/:jid.:type' do |jid, type|
      job = Job.fetch(jid)
      halt 404, { error: 'Job not found' }.to_json if job.nil?
      out = BLAST::Formatter.new(job, type)
      halt 404, { error: 'File not found"' }.to_json unless File.exist?(out.filepath)
      send_file out.filepath, filename: out.filename, type: out.mime
    end

    post '/cloud_share' do
      content_type :json
      request_params = JSON.parse(request.body.read)
      job = Job.fetch(request_params['job_id'])
      halt 404, { error: 'Job not found' }.to_json if job.nil?

      unless job.done?
        status 422
        { errors: ["Job #{request_params['job_id']} is not finished yet."] }.to_json
      end

      unless SequenceServer.config[:cloud_share_url]
        status 503
        { errors: ['Sorry, cloud sharing is not enabled on this server.'] }.to_json
      end

      begin
        job.as_archived_file do |archived_job_file|
          cloud_share_response = RestClient.post(
            SequenceServer.config[:cloud_share_url],
            {
              shared_job: {
                sender: {
                  email: request_params['sender_email']
                },
                archived_job_file: archived_job_file,
                original_job_id: job.id
              }
            }
          )

          return cloud_share_response.body
        end
      rescue RestClient::ExceptionWithResponse => e
        cloud_share_response = e.response

        case cloud_share_response.code
        when 413
          halt 413,
               { errors: ['Sorry, the results are too large to share, please consider \
                  using https://sequenceserver.com/cloud'] }.to_json
        when 422
          halt 422, JSON.parse(cloud_share_response.body).to_json
        else
          error cloud_share_response.code,
                { errors: ["Unexpected Cloudshare response: #{cloud_share_response.code}"] }.to_json
        end
      rescue Errno::ECONNREFUSED
        error 503, { errors: ['Sorry, the cloud sharing server may not be running. Try again later.'] }.to_json
      end
    end

    # Catches any exception raised within the app and returns JSON
    # representation of the error:
    # {
    #    title: ...,     // plain text
    #    message: ...,   // plain or HTML text
    #    more_info: ..., // pre-formatted text
    # }
    #
    # If the error class defines `http_status` instance method, its return
    # value will be used to set HTTP status. HTTP status is set to 500
    # otherwise.
    #
    # If the error class defines `title` instance method, its return value
    # will be used as title. Otherwise name of the error class is used as
    # title.
    #
    # All error classes should define `message` instance method that provides
    # a short and simple explanation of the error.
    #
    # If the error class defines `more_info` instance method, its return value
    # will be used as more_info, otherwise `backtrace.join("\n")` is used as
    # more_info.
    error 400..500 do
      error = env['sinatra.error']
      return unless error

      # All errors will have a message.
      error_data = { message: error.message }

      # If error object has a title method, use that, or use name of the
      # error class as title.
      error_data[:title] = if error.respond_to? :title
                             error.title
                           else
                             error.class.name
                           end

      # If error object has a more_info method, use that. If the error does not
      # have more_info, use backtrace.join("\n") as more_info.
      if error.respond_to? :more_info
        error_data[:more_info] = error.more_info
      elsif error.respond_to? :backtrace
        error_data[:more_info] = error.backtrace.join("\n")
      end

      if request.env['HTTP_ACCEPT'].to_s.include?('application/json') || request.path.end_with?('.json')
        status 422
        content_type :json
        error_data.to_json
      else
        content_type :html
        erb :error, locals: { error_data: error_data }, layout: true
      end
    end

    # Get the query sequences, selected databases, and advanced params used.
    def update_searchdata_from_job(searchdata)
      job = fetch_job(params[:job_id])
      return { error: 'Job not found' }.to_json if job.nil?
      return if job.imported_xml_file

      # Only read job.qfile if we are not going to use Database.retrieve.
      searchdata[:query] = File.read(job.qfile) unless params[:query]

      # Which databases to pre-select.
      searchdata[:preSelectedDbs] = job.databases

      # job.advanced may be nil in case of old jobs. In this case, we do not
      # override searchdata so that default advanced parameters can be applied.
      # Note that, job.advanced will be an empty string if a user deletes the
      # default advanced parameters from the advanced params input field. In
      # this case, we do want the advanced params input field to be empty when
      # the user hits the back button. Thus we do not test for empty string.
      method = job.method.to_sym
      if job.advanced && job.advanced !=
                         searchdata.dig(:options, method, :default, :attributes).to_a.join(' ')
        searchdata[:options] = searchdata[:options].deep_copy
        searchdata[:options][method]['last search'] = { attributes: [job.advanced] }
      end
    end

    def display_large_result_warning?(xml_file_size)
      threshold = SequenceServer.config[:large_result_warning_threshold].to_i
      return false unless threshold.positive?

      return false if params[:bypass_file_size_warning] == 'true'

      xml_file_size > threshold
    end

    def large_result_warning_payload(jid)
      {
        user_warning: 'LARGE_RESULT',
        download_links: [
          { name: 'Standard Tabular Report', url: "download/#{jid}.std_tsv" },
          { name: 'Full Tabular Report', url: "/download/#{jid}.full_tsv" },
          { name: 'Results in XML', url: "/download/#{jid}.xml" },
          { name: 'Pairwise', url: "/download/#{jid}.pairwise" },
        ]
      }
    end

    helpers do
      def root_path_prefix
        settings.root_path_prefix.to_s
      end
    end

    private

    def fetch_job(job_id)
      Job.fetch(job_id)
    end
  end
end
