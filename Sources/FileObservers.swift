//
//  FileObservers.swift
//  FileProvider
//
//  Created by Aleksander Slater on 29/03/2017.
//
//

import Foundation

// TODO: This can eventually go into the FileProviderBasicRemote class when its ready or FileProviderMonitor
public class FileObservers
{
    var bg : DispatchQueue { return DispatchQueue.global(qos:.background) } // TODO: a dedicated background observer queue?
    
    var tasks = Dictionary<String,FileProviderObservationTask>()

    public init()
    {
        
    }
    
    open func clear()
    {
        for task in tasks.values
        {
            task.stop()
        }
        tasks.removeAll()
    }
    
    open func registerNotification(path:String,type:FileProviderObservationType,provider:FileProviderObservationProvider,changed:@escaping (()->Void))
    {
        unregisterNotification(path:path)
        guard let task = provider.createObservationTask(path:path,type:type,changed:changed) else { return }
        tasks[path] = task
        bg.async
        {
            task.start()
        }
    }
    
    open func unregisterNotification(path:String)
    {
        if let old = tasks[path]
        {
            old.stop()
            tasks.removeValue(forKey:path)
        }
    }
    
    open func changedNotification(path:String)
    {
        if let task = tasks[path]
        {
            DispatchQueue.main.async // TODO: Should prob fire on queue defined in Task instead of assuming it should fire on the main queue
            {
                task.changed()
            }
        }
    }
}

public protocol FileProviderObservationProvider
{
    func createObservationTask(path:String,type:FileProviderObservationType,changed:@escaping (()->Void)) -> FileProviderObservationTask?
}

extension DropboxFileProvider : FileProviderObservationProvider
{
    public func createObservationTask(path:String,type:FileProviderObservationType,changed:@escaping (()->Void)) -> FileProviderObservationTask?
    {
        return DropboxProviderObservationTask(path:path,type:type,password:credential?.password ?? "",session:session,changed:changed)
    }
}

extension WebDAVFileProvider : FileProviderObservationProvider
{
    public func createObservationTask(path:String,type:FileProviderObservationType,changed:@escaping (()->Void)) -> FileProviderObservationTask?
    {
        return WebDavProviderObservationTask(path:path,type:type,provider:self,changed:changed)
    }
}

extension String
{
    var correctPath : String
    {
        var p = hasPrefix("/") ? self : "/" + self
        if p.hasSuffix("/")
        {
            p.remove(at: p.index(before:p.endIndex))
        }
        return p
    }
}

public enum FileProviderObservationType
{
    case children // the path and its children
    case descendants // the path and its children and their children etc.
}

open class FileProviderObservationTask
{
    open var path : String
    open var type : FileProviderObservationType
    open var session : URLSession
    open var changed : ((Void)->(Void))
    
    open func start()
    {
        fatalError("Subclasses need to implement the `start()` method.")
    }
    
    open func stop()
    {
        fatalError("Subclasses need to implement the `stop()` method.")
    }
    
    public init(path:String,type:FileProviderObservationType,session:URLSession,changed:@escaping ((Void)->(Void)))
    {
        self.path = path.correctPath
        self.type = type
        self.session = session
        self.changed = changed
    }
    
    open func fireChanged()
    {
        DispatchQueue.main.async
        {
            self.changed()
        }
    }
}

// TODO: Make use of FileProviderObservationType
class WebDavProviderObservationTask : FileProviderObservationTask
{
    var infoTask : URLSessionDataTask?
    var infoUrl : URL
    var stopped = false
    
    init(path:String,type:FileProviderObservationType,provider:WebDAVFileProvider,changed:@escaping ((Void)->(Void)))
    {
        infoUrl = provider.url(of: path)
        super.init(path:path,type:type,session:provider.session,changed:changed)
    }
    
    func getTag() -> (tag:String?,backoff:Int)
    {
        var reqProcessed = false
        var tag : String? = nil
        var backoff : Int = 20
        
        let url = infoUrl
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        // TODO: This needs to call a variant that only returns etags (or because thats the only thing we care about
        request.httpBody = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<D:propfind xmlns:D=\"DAV:\">\n<D:allprop/></D:propfind>".data(using: .utf8)
        request.setValue(String(request.httpBody!.count), forHTTPHeaderField: "Content-Length")
        infoTask = session.dataTask(with: request, completionHandler: { (data, response, error) in
            
            if let data = data
            {
                tag = WebDavProviderObservationTask.parseETag(data:data)
            }
            
            if tag == nil
            {
                backoff = 30 // TODO: A more dynamic backoff solution
            }
            
            reqProcessed = true
        })
        infoTask?.resume()
        
        while !reqProcessed
        {
            Thread.sleep(forTimeInterval:1)
        }
        
        return (tag:tag,backoff:backoff)
    }
    
    class func parseETag(data xmldata:Data) -> String?
    {
        do
        {
            let xml = try AEXMLDocument(xml:xmldata)
            var rootnode = xml.root
            var responsetag = "response"
            for node in rootnode.all ?? [] where node.name.lowercased().hasSuffix("multistatus")
            {
                rootnode = node
            }
            for node in rootnode.children where node.name.lowercased().hasSuffix("response")
            {
                responsetag = node.name
                break
            }
            
            if let rnode = rootnode[responsetag].first
            {
                for node in rnode.children
                {
                    if node.name.lowercased().hasSuffix("propstat")
                    {
                        for psnode in node.children
                        {
                            if psnode.name.lowercased().hasSuffix("prop")
                            {
                                for pnode in psnode.children
                                {
                                    if pnode.name.lowercased().hasSuffix("getetag")
                                    {
                                        if let tag = pnode.value
                                        {
                                            return tag
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch _
        {
            
        }
        return nil
    }
    
    override func start()
    {
        var oldTag : String? = nil
        
        while !stopped
        {
            let res = getTag()
            let tag = res.tag
            let backoff = res.backoff
            
            guard !stopped else { return }
            
            if oldTag != nil && tag != nil && oldTag != tag
            {
                oldTag = tag
                
                fireChanged()
            }
            else
            {
                oldTag = tag
            }
            
            if backoff > 0
            {
                Thread.sleep(forTimeInterval:Double(backoff))
            }
        }
    }
    
    override func stop()
    {
        stopped = true
        infoTask?.suspend()
        infoTask = nil
    }
}

// TODO: Make use of FileProviderObservationType
class DropboxProviderObservationTask : FileProviderObservationTask
{
    private var password : String
    
    var cursorTask : URLSessionDataTask?
    var changesTask : URLSessionDataTask?
    
    var stopped = false
    
    static var cursors = Dictionary<String,String>()
    
    init(path:String,type:FileProviderObservationType,password:String,session:URLSession,changed:@escaping ((Void)->(Void)))
    {
        self.password = password
        super.init(path:path,type:type,session:session,changed:changed)
    }
    
    func getCursor() -> String?
    {
        var cursor : String? = nil
        var reqProcessed = false
        
        let url = URL(string: "https://api.dropboxapi.com/2/files/list_folder/get_latest_cursor")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestDictionary : [String:AnyObject] = ["path":path as NSString]
        let json = String(jsonDictionary:requestDictionary) ?? ""
        request.httpBody = json.data(using: .utf8)
        cursorTask = session.dataTask(with: request, completionHandler: { (data, response, error) in
            
            if let data = data, let jsonStr = String(data: data, encoding: .utf8)
            {
                let json = jsonStr.deserializeJSON()
                cursor = json?["cursor"] as? String
            }
            
            reqProcessed = true
        })
        cursorTask?.resume()
        
        while !reqProcessed
        {
            Thread.sleep(forTimeInterval:1)
        }
        
        return cursor
    }
    
    func getChanges(cursor cur:String) -> (cursor:String,changes:Bool,backoff:Int)
    {
        var changes = false
        var backoff = 0
        let cursor = cur
        
        var reqProcessed = false
        
        let url = URL(string: "https://notify.dropboxapi.com/2/files/list_folder/longpoll")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestDictionary : [String:AnyObject] = ["cursor": cursor as NSString]
        let json = String(jsonDictionary:requestDictionary) ?? ""
        request.httpBody = json.data(using: .utf8)
        changesTask = session.dataTask(with: request, completionHandler: { (data, response, error) in
            
            if let data = data, let jsonStr = String(data: data, encoding: .utf8)
            {
                let json = jsonStr.deserializeJSON()
                backoff = json?["backoff"] as? Int ?? backoff
                changes = json?["changes"] as? Bool ?? changes
            }
            
            reqProcessed = true
        })
        changesTask?.resume()
        
        while !reqProcessed
        {
            Thread.sleep(forTimeInterval:1)
        }
        
        return (cursor:cursor,changes:changes,backoff:backoff)
    }
    
    override func start()
    {
        var cur : String? = DropboxProviderObservationTask.cursors[path]
        while cur == nil
        {
            cur = getCursor()
            if stopped { break }
        }
        
        guard !stopped else { return }
        guard var cursor = cur else { return }
        
        while !stopped
        {
            let res = getChanges(cursor:cursor)
            
            guard !stopped else { return }
            
            cursor = res.cursor
            if res.changes
            {
                fireChanged()
                
                if let c = getCursor()
                {
                    cursor = c
                    DropboxProviderObservationTask.cursors[path] = c
                }
            }
            if res.backoff > 0
            {
                Thread.sleep(forTimeInterval:Double(res.backoff))
            }
        }
    }
    
    override func stop()
    {
        stopped = true
        cursorTask?.suspend()
        cursorTask = nil
        changesTask?.suspend()
        changesTask = nil
    }
}
