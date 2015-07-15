require 'terminator'

module FileHelper

  # Provide access to the Rails logger
  def self.logger
    Rails.logger
  end

  #
  # Test if a file should be accepted based on an expected kind
  # - file is passed the file uploaded to Doubtfire (a hash with all relevant data about the file)
  #
  def self.accept_file(file, name, kind)
    logger.debug "FileHelper accept_file #{file}, #{name}, #{kind}"
    # puts "FileHelper accept_file #{file}, #{name}, #{kind}"

    fm = FileMagic.new(FileMagic::MAGIC_MIME)
    mime = fm.file file.tempfile.path
    logger.debug " -- #{name} is mime type: #{mime}"
    # puts " -- #{name} is mime type: #{mime}"

    valid = true

    case kind
    when 'image'
      accept = ["image/png", "image/gif", "image/bmp", "image/tiff", "image/jpeg", "image/x-ms-bmp"]
    when 'code'
      accept = ["text/x-pascal", "text/x-c", "text/x-c++", "text/plain", "text/"]
    when 'document'
      accept = [ # -- one day"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 # --"application/msword", 
                 "application/pdf" ]
      valid = pdf_valid? file.tempfile.path
    else
      logger.error "Unknown type '#{kind}' provided for '#{name}'"
      puts "Unknown type '#{kind}' provided for '#{name}'"
      return false
    end
    
    # result is true when...
    mime.start_with?(*accept) && valid
  end


  #
  # Sanitize the passed in paths, and ensure each part is valid
  # Will kill things like ../ etc or spaces in paths
  #
  def self.sanitized_path(*paths)
    safe_paths = paths.map do | path_name |
      path_name.strip.tap do |name|
        # Finally, replace all non alphanumeric, underscore
        # or periods with underscore
        name.gsub! /[^\w\-]/, '_'
      end
    end

    File.join(safe_paths)
  end

  #
  # Sanitize the passed in filename -- should not include any path details
  #
  def self.sanitized_filename(filename)
    filename.strip.tap do |name|
      # NOTE: File.basename doesn't work right with Windows paths on Unix
      # get only the filename, not the whole path
      name.sub! /\A.*(\\|\/)/, ''
      # Finally, replace all non alphanumeric, underscore
      # or periods with underscore
      name.gsub! /[^\w\.\-]/, '_'
    end
  end

  #
  # Generates a path for storing student work
  # type = [:new, :in_process, :done, :pdf, :plagarism]
  #
  def self.student_work_dir(type = nil, task = nil, create = true)
    file_server = Doubtfire::Application.config.student_work_dir
    dst = "#{file_server}/" # trust the server config and passed in type for paths

    if not (type.nil? || task.nil?)
      if type == :pdf
        dst << sanitized_path("#{task.project.unit.code}-#{task.project.unit.id}","#{task.project.student.username}", "#{type}") << "/"
      elsif type == :done
        dst << sanitized_path("#{task.project.unit.code}-#{task.project.unit.id}","#{task.project.student.username}", "#{type}", "#{task.id}") << "/"
      elsif type == :plagarism
        dst << sanitized_path("#{task.project.unit.code}-#{task.project.unit.id}","#{task.project.student.username}", "#{type}", "#{task.id}") << "/"
      elsif  # new and in_process -- just have task id
        # Add task id to dst if we want task
        dst << "#{type}/#{task.id}/"
      end
    elsif (not type.nil?)
      if [:in_process, :new].include? type
        # Add task id to dst if we want task
        dst << "#{type}/"
      else
        raise "Error in request to student work directory"
      end
    end

    # Create current dst directory should it not exist
    if create
      FileUtils.mkdir_p(dst)
    end
    dst
  end

  #
  # Generates a path for storing student portfolios
  #
  def self.student_portfolio_dir(project, create = true)
    file_server = Doubtfire::Application.config.student_work_dir
    dst = "#{file_server}/portfolio/" # trust the server config and passed in type for paths

    dst << sanitized_path("#{project.unit.code}-#{project.unit.id}", "#{project.student.username}" )

    # Create current dst directory should it not exist
    if create
      FileUtils.mkdir_p(dst)
    end
    dst
  end

  def self.compress_pdf(path)
    #trusting path... as it needs to be replaced
    #puts "compressing #{path}"
    # only compress things over 1.2Mb
    return if File.size?(path) < 1200000
    
    begin
      tmp_file = File.join( Dir.tmpdir, 'doubtfire', 'compress', "#{File.dirname(path).split(File::Separator).last}-file.pdf" )
      FileUtils.mkdir_p(File.join( Dir.tmpdir, 'doubtfire', 'compress' ))

      exec = "gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.3 -dDetectDuplicateImages=true -dPDFSETTINGS=/screen -dNOPAUSE -dBATCH  -dQUIET -sOutputFile=\"#{tmp_file}\" \"#{path}\" >>/dev/null 2>>/dev/null"

      # try with ghostscript
      didCompress = false
      Terminator.terminate 120 do
        didCompress = system exec
      end
      
      if !didCompress
        logger.info "Failed to compress pdf: #{path} using GS"

        exec = "convert \"#{path}\" -compress Zip \"#{tmp_file}\" >>/dev/null 2>>/dev/null"

        # try with convert
        Terminator.terminate 120 do
          didCompress = system exec
        end

        if !didCompress
          logger.error "Failed to compress pdf: #{path}\n#{exec}"
          puts "Failed to compress pdf: #{path}\n#{exec}"
        end
      end

      if didCompress
        FileUtils.mv tmp_file, path
      end

    rescue 
      logger.error("Failed to compress pdf: #{path}")
    end

    if File.exists? tmp_file
      FileUtils.rm tmp_file
    end
  end

  #
  # Move files between stages - new -> in process -> done
  #
  def self.move_files(from_path, to_path)
    # move into the new dir - and mv files to the in_process_dir
    Dir.chdir(from_path)
    FileUtils.mv Dir.glob("*"), to_path, :force => true
    Dir.chdir(to_path)
    begin
      #remove from_path as files are now "in process"
      FileUtils.rm_r(from_path)
    rescue
      logger.warn "failed to rm #{from_path}"
    end
  end

  #
  # Convert the files in the indicated folder into PDFs and move to 
  # a dest_path
  #
  def self.convert_files_to_pdf(from_path, dest_path)
    #
    # Get access to all files to process (ensure we only work with <no>.[cover|document|code|image] etc...)
    #
    in_process_files = Dir.entries(from_path).select { | f | (f =~ /^\d{3}\.(cover|document|code|image)/) == 0 }
    if in_process_files.length < 1
      logger.error "No files found in #{from_path}"
      puts "Error - No files found in #{from_path}"
      return nil
    end

    #
    # Map each process file to have extra info i.e.:
    #
    # file.idx            = 0..n
    # file.path           = actual file dir sitting in in_process directory
    # file.ext            = file extension
    # file.type           = cover/image/code/document
    # file.actualfile     = actual file variable that can be used - File.open(path)
    #
    files = []
    in_process_files.each do | file |
      # file0.code.png
      idx = file.split('.').first.to_i
      type = file.split('.').second
      path = File.join("#{from_path}", "#{file}")
      ext = File.extname(path).downcase
      actualfile = File.open(path)
      files << { :idx => idx, :type => type, :path => path, :ext => ext, :actualfile => actualfile }
    end
    
    # ensure the dest_path exists
    if not Dir.exists? dest_path
      FileUtils.mkdir_p(dest_path)
    end
    
    #
    # Begin processing... 
    #
    pdf_paths = []
    files.each do | file |
      outpath = "#{dest_path}/#{file[:idx]}.#{file[:type]}.pdf"
      
      convert_to_pdf(file, outpath)
      # puts file
      pdf_paths[file[:idx]] = outpath
      begin
        file[:actualfile].close
      rescue
      end
    end

    pdf_paths
  end

  #
  # Tests if a PDF is valid / corrupt
  #
  def self.pdf_valid?(file)
    # puts "pdftk #{file} output dont_ask /dev/null"

    didSucceed = false

    Terminator.terminate 30 do
      didSucceed = system "pdftk #{file} output /dev/null dont_ask"
    end    

    didSucceed
  end

  #
  # Copy a PDF into place
  #
  def self.copy_pdf(file, dest_path)
    if pdf_valid? file
      compress_pdf(file)
      FileUtils.cp file, dest_path
      true
    else
      false
    end
  end

  #
  # Converts the given file to a pdf
  #  
  def self.convert_to_pdf(file, outdir)
    case file[:type]
    when 'image'
      img_to_pdf(file, outdir)
    when 'code'
      code_to_pdf(file, outdir)
    when 'document'
      doc_to_pdf(file, outdir)
    when 'cover'
      cover_to_pdf(file, outdir)
    end
  end
  
  #
  # Converts the code provided to a pdf
  #
  def self.code_to_pdf(file, outdir)
    # decide language syntax highlighting
    case file[:ext]
    when '.cpp', '.cs'
      lang = :cplusplus
    when '.c', '.h'
      lang = :c
    when '.java'
      lang = :java
    when '.pas'
      lang = :delphi
    else
      # should follow basic C syntax (if, else etc...)
      lang = :c
    end
    # code -> HTML
    html_body = CodeRay.scan_file(file[:actualfile], lang).html(:wrap => :div, :tab_width => 2, :css => :class, :line_numbers => :table, :line_number_anchors => false)

    # HTML -> PDF
    kit = PDFKit.new(html_body, :page_size => 'A4', :header_right => "[page]/[toPage]", :margin_top => "10mm", :margin_right => "5mm", :margin_bottom => "5mm", :margin_left => "5mm", :lowquality => true, :minimum_font_size => 8)
    kit.stylesheets << Rails.root.join("vendor/assets/stylesheets/coderay.css")
    kit.to_file(outdir)
  end
  
  #
  # Converts the image provided to a pdf
  #
  def self.img_to_pdf(file, outdir)
    img = Magick::Image.read(file[:path]).first
    # resize the image if its too big (e.g., taken with a digital camera)
    if img.columns > 1000 || img.rows > 1000
      # resize such that it's 1000px in width
      scale = 1
      if img.columns > img.rows
        scale = 1000.0 / img.columns
      else
        scale = 1000.0 / img.rows
      end
      img = img.resize(scale)
    end
    img.write("pdf:#{outdir}") { self.quality = 75 }
  end

  #
  # Converts the document provided to a pdf
  #
  def self.doc_to_pdf(file, outdir)
    # puts file
    # if uploaded a PDF, then directly pass in
    # if file[:ext] == '.pdf'
      # copy the file over (note we need to copy it into
      # output_file as file will be removed at the end of this block)
      
      begin
        file[:actualfile].close()
      rescue
      end

      copy_pdf(file[:path], outdir)

      begin
        file[:actualfile] = File.open(file[:path])
      rescue
      end
    # end
    # TODO msword doc...
  end

  #
  # Converts the cover page provided to a pdf
  #
  def self.cover_to_pdf(file, outdir)
    # puts file
    kit = PDFKit.new(
      read_file_to_str(file[:path]), 
      :page_size => 'A4', 
      :margin_top => "30mm", :margin_right => "30mm", :margin_bottom => "30mm", :margin_left => "30mm"
      )
    kit.stylesheets << Rails.root.join("vendor/assets/stylesheets/doubtfire-coverpage.css")
    kit.to_file outdir
  end

  #
  # Read the file and return its contents as a string
  #
  def self.read_file_to_str(filename)
    result = ''
    f = File.open(filename, "r") 
    begin
      f.each_line do |line|
        result += line
      end
    ensure
      f.close unless f.nil?
    end
    result
  end

  #
  # Aggregate a list of PDFs into a single PDF file
  # - returns boolean indicating success
  #
  def self.aggregate(pdf_paths, final_pdf_path)
    didCompile = false
    Terminator.terminate 180 do
      didCompile = system "pdftk #{pdf_paths.join ' '} cat output '#{final_pdf_path}' dont_ask compress"
    end

    if !didCompile
      logger.error "failed to create #{final_pdf_path}\n -> pdftk #{pdf_paths.join ' '} cat output #{final_pdf_path}"
      puts "failed to create #{final_pdf_path}\n -> pdftk #{pdf_paths.join ' '} cat output #{final_pdf_path}"
    end
    didCompile
  end

  def self.path_to_plagarism_html(match_link)
    to_dir = student_work_dir(:plagarism, match_link.task)

    File.join(to_dir, "link_#{match_link.other_task.id}.html")
  end

  #
  # Save the passed in html to a file.
  #
  def self.save_plagiarism_html(match_link, html)
    File.open(path_to_plagarism_html(match_link), 'w') do |out_file|  
      out_file.puts html
    end
  end

  #
  # Delete the html for a plagarism link
  #
  def self.delete_plagarism_html(match_link)
    rm_file = path_to_plagarism_html(match_link)
    if File.exists? rm_file
      FileUtils.rm(rm_file)
      to_dir = student_work_dir(:plagarism, match_link.task)

      if Dir[File.join(to_dir, '*.html')].count == 0
        FileUtils.rm_rf(to_dir)
      end
    end
  end

end
