import Foundation
import NaturalLanguage
let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let raw=try JSONSerialization.jsonObject(with:input) as! [String:Any]
let rows=raw["rows"] as! [[String:Any]]
struct Vector {let values:[Double];let language:String;let revision:Int}
func embed(_ s:String)->Vector? {
 let lang=NLLanguageRecognizer.dominantLanguage(for:s) ?? .english
 guard let e=NLEmbedding.sentenceEmbedding(for:lang),let v=e.vector(for:s) else{return nil}
 return Vector(values:v,language:lang.rawValue,revision:e.revision)
}
func cos(_ a:Vector,_ b:Vector)->Double? {
 guard a.language==b.language,a.revision==b.revision,a.values.count==b.values.count else{return nil}
 let dot=zip(a.values,b.values).reduce(0.0){$0+$1.0*$1.1}
 let aa=a.values.reduce(0.0){$0+$1*$1},bb=b.values.reduce(0.0){$0+$1*$1}
 return dot/sqrt(aa*bb)
}
var rankings:[[String:Any]]=[]
for row in rows where row["related"] as? Bool == true {
 let language=row["declared_language"] as! String
 let query=embed(row["query"] as! String)!
 let candidates=rows.filter{($0["id"] as! String)==(row["id"] as! String) || ($0["id"] as! String).hasPrefix("control-\(language)-")}
 let scores=candidates.map{ candidate -> [String:Any] in
  let id=candidate["id"] as! String
  let vector=embed((candidate["subject"] as! String)+" "+(candidate["content"] as! String))!
  return ["id":id,"cosine":cos(query,vector) as Any? ?? NSNull(),"is_target":id==(row["id"] as! String),"dimension":vector.values.count]
 }.sorted{($0["cosine"] as? Double ?? -1)>($1["cosine"] as? Double ?? -1)}
 rankings.append(["query_id":row["id"]!,"query":row["query"]!,"language":language,"dimension":query.values.count,"query_norm":sqrt(query.values.reduce(0.0){$0+$1*$1}),"target_rank_among_unrelated_controls":scores.firstIndex{($0["is_target"] as? Bool)==true}!+1,"scores":scores])
}
let result:[String:Any]=["rankings":rankings,"apple_en_revision":NLEmbedding.currentSentenceEmbeddingRevision(for:.english),"apple_fr_revision":NLEmbedding.currentSentenceEmbeddingRevision(for:.french),"classification":"Pairwise score diagnostic, not a retrieval benchmark"]
let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
