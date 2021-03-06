require 'cgi'
require 'base64'

module Aqua
  module Store
    module CouchDB
      # This module of storage methods was built to be flexible enough to step in as a replacement 
      # for CouchRest core or another super lite CouchDB library. A lot of the methods are added for that
      # convenience, and not for the needs of Aqua. Adding the module to a Mash/Hash class is sufficient
      # to get the full core access library.
      #
      # @see Aqua::Storage for details on the require methods for a storage library.
      module StorageMethods
        
        def self.included( klass ) 
          klass.class_eval do 
            include InstanceMethods
            extend ClassMethods
          end
        end 
        
        module ClassMethods
          # Initializes a new storage document and saves it without raising any errors
          # 
          # @param [Hash, Mash]
          # @return [Aqua::Storage, false] On success it returns an aqua storage object. On failure it returns false.
          # 
          # @api public
          def create( hash )
            doc = new( hash )
            doc.save
          end
    
          # Initializes a new storage document and saves it raising any errors.
          # 
          # @param [Hash, Mash]
          # @return [Aqua::Storage] On success it returns an aqua storage object. 
          # @raise Any of the CouchDB exceptions
          # 
          # @api public
          def create!( hash )
            doc = new( hash )
            doc.save!
          end
          
        end     
        
        module InstanceMethods
          # Initializes a new storage document. 
          # 
          # @param [Hash, Mash]
          # @return [Aqua::Storage] a Hash/Mash with some extras
          #
          # @api public
          def initialize( hash={} )
            hash = Mash.new( hash ) unless hash.empty?
            self.id = hash.delete(:id) if hash[:id]
          
            # ignore these keys
            hash.delete(:rev)   # This is omited to aleviate confusion
            hash.delete(:_rev)  # CouchDB determines _rev attribute
            hash.delete(:_id)   # this is set via by the id=(value) method 
            # TODO: have to deal with attachments as well
          
            # feed the rest of the hash to the super 
            super( hash )      
          end 
        
          # Saves an Aqua::Storage instance to CouchDB as a document. Save can be deferred for bulk saving.
          #
          # @param [optional true, false] Determines whether the document is cached for bulk saving later. true will cause it to be defered. Default is false.
          # @return [Aqua::Storage, false] Will return false if the document is not saved. Otherwise it will return the Aqua::Storage object.
          #
          # @api public
          def save( defer=false )
            save_logic( defer )  
          end 
        
          # Saves an Aqua::Storage instance to CouchDB as a document. Save can be deferred for bulk saving from the database.
          # Unlike #save, this method will raise an error if the document is not saved.
          # 
          # @param [optional true, false] Determines whether the document is cached for bulk saving later. true will cause it to be defered. Default is false.
          # @return [Aqua::Storage] On success.
          #
          # @api public
          def commit( defer=false )
            save_logic( defer, false )
          end
          alias :save! :commit 
        
          # Internal logic used by save, save! and commit to save an object.
          #
          # @param [optional true, false] Determines whether a object cached for save in the database in bulk. By default this is false.
          # @param [optional true, false] Determines whether an exception is raised or whether false is returned.
          # @return [Aqua::Storage, false] Depening on the type of execption masking and also the outcome
          # @raise Any of the CouchDB execptions.
          #
          # @api private
          def save_logic( defer=false, mask_exception = true )
            encode_attachments if self[:_attachment] 
            ensure_id
            if defer
              database.add_to_bulk_cache( self )
            else
              # clear any bulk saving left over ...
              database.bulk_save if database.bulk_cache.size > 0
              if mask_exception
                save_now
              else
                save_now( false )
              end       
            end 
          end     
        
          # Internal logic used by save_logic to save an object immediately instead of deferring for bulk save.
          #
          # @param [optional true, false] Determines whether an exception is raised or whether false is returned.
          # @return [Aqua::Storage, false] Depening on the type of execption masking and also the outcome
          # @raise Any of the CouchDB execptions.
          #
          # @api private
          def save_now( mask_exception = true ) 
            begin
              result = CouchDB.put( uri, self )
            rescue Exception => e
              if mask_exception
                result = false
              else
                raise e
              end    
            end
          
            if result && result['ok']
              update_version( result )
              self
            else    
              result 
            end 
          end
        
          # couchdb database url for this document
          # @return [String] representing CouchDB uri for document 
          # @api public
          def uri
            database.uri + '/' + ensure_id
          end 
          
          # retrieves self from CouchDB database
          # @return [Hash] representing the CouchDB data
          # @api public
          def retrieve
            self.class.new( CouchDB.get( uri ) )
          end  
        
          # Deletes an document from CouchDB. Delete can be deferred for bulk saving/deletion.
          #
          # @param [optional true, false] Determines whether the document is cached for bulk saving later. true will cause it to be defered. Default is false.
          # @return [String, false] Will return a json string with the response if successful. Otherwise returns false.
          #
          # @api public
          def delete(defer = false)
            delete_logic( defer )
          end
        
          # Deletes an document from CouchDB. Delete can be deferred for bulk saving/deletion. This version raises an exception if an error other that resource not found is raised.
          #
          # @param [optional true, false] Determines whether the document is cached for bulk saving later. true will cause it to be defered. Default is false.
          # @return [String, false] Will return a json string with the response if successful. It will return false if the resource was not found. Other exceptions will be raised.
          # @raise Any of the CouchDB exceptions
          #
          # @api public
          def delete!(defer = false)
            delete_logic( defer, false ) 
          end
        
          # Internal logic used by delete and delete! to delete a resource.
          #
          # @param [optional true, false] Determines whether resource is deleted immediately or saved for bulk processing.
          # @param [optional true, false] Determines whether an exception is raised or whether false is returned.
          # @return [String, false] Depening on the type of execption masking and also the outcome
          # @raise Any of the CouchDB execptions.
          #
          # @api private
          def delete_logic( defer = false, mask_exceptions = true )
            if defer
              database.add_to_bulk_cache( { '_id' => self['_id'], '_rev' => rev, '_deleted' => true } )
            else
              begin
                delete_now
              rescue Exception => e
                if mask_exceptions || e.class == CouchDB::ResourceNotFound
                  false
                else 
                  raise e
                end    
              end  
            end 
          end  
        
          # Internal logic used by delete_logic delete a resource immediately.
          #
          # @return [String, false] Depening on the type of execption masking and also the outcome
          # @raise Any of the CouchDB execptions.
          #
          # @api private
          def delete_now
            revisions.each do |rev_id| 
              CouchDB.delete( "#{uri}?rev=#{rev_id}" )
            end
            true   
          end
          
          # Gets revision history, which is needed by Delete to remove all versions of a document
          # 
          # @return [Array] Containing strings with revision numbers
          # 
          # @api semi-private
          def revisions
            active_revisions = []
            begin
              hash = CouchDB.get( "#{uri}?revs_info=true" )
            rescue
              return active_revisions
            end    
            hash['_revs_info'].each do |rev_hash|
              active_revisions << rev_hash['rev'] if ['disk', 'available'].include?( rev_hash['status'] )
            end
            active_revisions  
          end  
             
        
          # sets the database
          # @param   [Aqua::Store::CouchDB::Database]
          # @return [Aqua::Store::CouchDB::Database]
          # @api private
          attr_writer :database 
        
          # retrieves the previously set database or sets the new one with a default value
          # @return [Aqua::Store::CouchDB::Database]
          # @api private
          def database
            @database ||= determine_database
          end  
        
          # Looks to CouchDB.database_strategy for information about how the CouchDB store has generally
          # been configured to store its data across databases and/or servers. In some cases the class for
          # the parent object has configuration details about the database and server to use.
          # @todo Build the strategies in CouchDB. Use them here
          # @api private
          def determine_database
            Database.create # defaults to database 'aqua' using default server :aqua   
          end  
        
          # setters and getters couchdb document specifics -------------------------
          
          # Gets the document id. In this engine id and _id are different data. The main reason for this is that
          # CouchDB needs a relatively clean string as the key, where as the user can assign a messy string to
          # the id. The user can continue to use the messy string since the engine also has access to the _id.
          # 
          # @return [String]
          #
          # @api public 
          def id
            self[:id]
          end
          
          # Allows the id to be set. If the id is changed after creation, then the CouchDB document for the old
          # id is deleted, and the _rev is set to nil, making it a new document. The id can only be a string (right now).
          #
          # @return [String, false] Will return the string it received if it is indeed a string. Otherwise it will
          # return false.
          #
          # @api public 
          def id=( str )
            if str.respond_to?(:match)
              escaped = escape_for_id( str )
              
              # CLEANUP: do a bulk delete request on the old id, now that it has changed
              delete(true) if !new? && escaped != self[:_id]
              
              self[:id] = str
              self[:_id] = escaped 
              str 
            end  
          end  
    
          # Returns CouchDB document revision identifier.
          # 
          # @return [String]
          #
          # @api semi-public
          def rev
            self[:_rev]
          end
    
          protected 
            def rev=( str )
              self[:_rev] = str
            end   
          public 
          
          # Updates the id and rev after a document is successfully saved.
          # @param [Hash] Result returned by CouchDB document save
          # @api private
          def update_version( result ) 
            self.id     = result['id']
            self.rev    = result['rev']
          end  
    
          # Returns true if the document has never been saved or false if it has been saved.
          # @return [true, false]
          # @api public
          def new?
            !rev
          end
          alias :new_document? :new? 
        
          # Returns true if a document exists at the CouchDB uri for this document. Otherwise returns false
          # @return [true, false]
          # @api public
          def exists?
            begin 
              CouchDB.get uri
              true
            rescue
              false
            end    
          end  
        
          # gets a uuid from the server if one doesn't exist, otherwise escapes existing id.
          # @api private
          def ensure_id
            self[:_id] = ( id ? escape_doc_id : database.server.next_uuid )
          end 
          
          # Escapes document id. Different strategies for design documents and normal documents.
          # @api private
          def escape_doc_id
            escape_for_id( id )
          end
          
          # Escapes a string for id usage
          # @api private
          def escape_for_id( str )
            str.match(/^_design\/(.*)/) ? "_design/#{CGI.escape($1)}" : CGI.escape(str)
          end    
          

          # TODO: Attachments
          # def encode_attachments(attachments)
          #   attachments.each do |key, value|
          #     next if value['stub']
          #     value['data'] = base64(value['data'])
          #   end
          #   attachments
          # end
          # 
          # def base64(data)
          #   Base64.encode64(data).gsub(/\s/,'')
          # end
            
        end # InstanceMethods           
        
      end # StoreMethods
    end # CouchDB
  end # Store
end # Aqua     