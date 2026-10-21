import Foundation
import NaturalLanguage

struct Pair {
    let id: String, query: String, subject: String, content: String, language: String
    let related: Bool
}
let pairs = [
 Pair(id:"old-en-1",query:"I prefer short explanations.",subject:"reply style",content:"Keep messages concise.",language:"en",related:true),
 Pair(id:"old-en-2",query:"Use brief answers.",subject:"output preference",content:"Respond concisely.",language:"en",related:true),
 Pair(id:"old-en-3",query:"Give compact replies.",subject:"communication preference",content:"Provide short responses.",language:"en",related:true),
 Pair(id:"old-en-4",query:"I develop native interfaces for Apple computers.",subject:"software stack",content:"My macOS applications use SwiftUI.",language:"en",related:true),
 Pair(id:"old-en-5",query:"Questions should be answered briefly.",subject:"response length",content:"I dislike lengthy responses.",language:"en",related:true),
 Pair(id:"en-6",query:"My app keeps its records on the device.",subject:"storage",content:"The application persists data locally.",language:"en",related:true),
 Pair(id:"en-7",query:"I need to operate without internet access.",subject:"connectivity",content:"Offline operation is required.",language:"en",related:true),
 Pair(id:"en-8",query:"Please retain the original documents.",subject:"file preservation",content:"Never discard source files.",language:"en",related:true),
 Pair(id:"en-9",query:"Get my approval before sending a message.",subject:"outbound communication",content:"Ask permission prior to transmitting correspondence.",language:"en",related:true),
 Pair(id:"en-10",query:"Measurements should be expressed in meters and kilograms.",subject:"units",content:"Use the metric system.",language:"en",related:true),
 Pair(id:"en-11",query:"I follow a vegetarian diet.",subject:"food",content:"My meals exclude meat.",language:"en",related:true),
 Pair(id:"en-12",query:"Use dark colors for the interface.",subject:"appearance",content:"The application should have a dark theme.",language:"en",related:true),
 Pair(id:"en-13",query:"Keep the existing work untouched.",subject:"editing safety",content:"Preserve all current modifications.",language:"en",related:true),
 Pair(id:"en-14",query:"Notify me when the task is finished.",subject:"completion",content:"Send an alert upon completion.",language:"en",related:true),
 Pair(id:"en-15",query:"I would rather communicate in French.",subject:"language",content:"Respond in French whenever possible.",language:"en",related:true),
 Pair(id:"en-16",query:"Run tasks one after another.",subject:"execution ordering",content:"Execute operations sequentially.",language:"en",related:true),
 Pair(id:"fr-1",query:"Je veux des réponses brèves.",subject:"style de réponse",content:"Réponds de manière concise.",language:"fr",related:true),
 Pair(id:"fr-2",query:"Il faut conserver les documents originaux.",subject:"préservation",content:"Ne supprime jamais les fichiers sources.",language:"fr",related:true),
 Pair(id:"fr-3",query:"L'application doit fonctionner sans connexion internet.",subject:"connectivité",content:"Le fonctionnement hors ligne est indispensable.",language:"fr",related:true),
 Pair(id:"fr-4",query:"Demande mon accord avant de transmettre un courrier.",subject:"communication",content:"Tout envoi de message nécessite une autorisation préalable.",language:"fr",related:true),
 Pair(id:"fr-5",query:"Les tâches doivent être effectuées l'une après l'autre.",subject:"ordre",content:"Exécute les opérations séquentiellement.",language:"fr",related:true),
 Pair(id:"fr-6",query:"Je préfère une interface sombre.",subject:"apparence",content:"Utilise un thème foncé.",language:"fr",related:true),
 Pair(id:"fr-7",query:"Je ne mange pas de viande.",subject:"alimentation",content:"Mon régime est végétarien.",language:"fr",related:true),
 Pair(id:"fr-8",query:"Préviens-moi dès que le travail est terminé.",subject:"notifications",content:"Avertis-moi à la fin de la tâche.",language:"fr",related:true),
 Pair(id:"control-en-1",query:"I prefer short explanations.",subject:"transport",content:"I enjoy cycling outdoors.",language:"en",related:false),
 Pair(id:"control-en-2",query:"Use brief answers.",subject:"database",content:"Schema migrations rely on SQLite.",language:"en",related:false),
 Pair(id:"control-en-3",query:"Give compact replies.",subject:"cuisine",content:"The recipe requires ripe tomatoes.",language:"en",related:false),
 Pair(id:"control-en-4",query:"I need to operate without internet access.",subject:"garden",content:"The roses need watering every morning.",language:"en",related:false),
 Pair(id:"control-en-5",query:"Measurements should be expressed in meters and kilograms.",subject:"time",content:"The meeting starts at noon.",language:"en",related:false),
 Pair(id:"control-fr-1",query:"Je veux des réponses brèves.",subject:"transport",content:"J'aime faire du vélo dans la forêt.",language:"fr",related:false),
 Pair(id:"control-fr-2",query:"Il faut conserver les documents originaux.",subject:"alimentation",content:"Les tomates doivent être bien mûres.",language:"fr",related:false),
 Pair(id:"control-fr-3",query:"L'application doit fonctionner sans connexion internet.",subject:"jardin",content:"Les fleurs nécessitent un arrosage quotidien.",language:"fr",related:false),
 Pair(id:"contradiction-en-1",query:"I prefer short explanations.",subject:"reply style",content:"Give detailed and lengthy explanations.",language:"en",related:false),
 Pair(id:"contradiction-en-2",query:"I need to operate without internet access.",subject:"connectivity",content:"An internet connection is mandatory.",language:"en",related:false),
 Pair(id:"contradiction-en-3",query:"Please retain the original documents.",subject:"file preservation",content:"Delete the original documents after importing them.",language:"en",related:false),
 Pair(id:"contradiction-en-4",query:"Get my approval before sending a message.",subject:"outbound communication",content:"Send messages automatically without asking permission.",language:"en",related:false),
 Pair(id:"contradiction-fr-1",query:"Je veux des réponses brèves.",subject:"style de réponse",content:"Fournis des réponses longues et détaillées.",language:"fr",related:false),
 Pair(id:"contradiction-fr-2",query:"Il faut conserver les documents originaux.",subject:"préservation",content:"Supprime les documents originaux après l'importation.",language:"fr",related:false),
 Pair(id:"contradiction-fr-3",query:"L'application doit fonctionner sans connexion internet.",subject:"connectivité",content:"Une connexion internet permanente est obligatoire.",language:"fr",related:false),
 Pair(id:"contradiction-fr-4",query:"Demande mon accord avant de transmettre un courrier.",subject:"communication",content:"Envoie le courrier immédiatement sans demander d'autorisation.",language:"fr",related:false),
]
struct Vector {
 let values:[Double], language:String, revision:Int
}
func embedding(_ text:String, forcedLanguage:String? = nil) -> Vector? {
 let language = forcedLanguage.map(NLLanguage.init(rawValue:)) ?? NLLanguageRecognizer.dominantLanguage(for:text) ?? .english
 guard let model = NLEmbedding.sentenceEmbedding(for:language), let values = model.vector(for:text), !values.isEmpty else { return nil }
 return Vector(values:values,language:language.rawValue,revision:model.revision)
}
func cosine(_ a:Vector?,_ b:Vector?) -> Double? {
 guard let a, let b, a.language==b.language, a.revision==b.revision, a.values.count==b.values.count else {return nil}
 let dot=zip(a.values,b.values).reduce(0.0){$0+$1.0*$1.1}
 let aa=a.values.reduce(0.0){$0+$1*$1},bb=b.values.reduce(0.0){$0+$1*$1}
 return aa>0 && bb>0 ? dot/sqrt(aa*bb):nil
}
func json(_ value:Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
func chunks(_ text:String) -> [String] {
 let tokenizer=NLTokenizer(unit:.sentence);tokenizer.string=text
 return tokenizer.tokens(for:text.startIndex..<text.endIndex).map{String(text[$0])}
}
func words(_ text:String) -> Set<String> {
 Set(text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil).split(whereSeparator:{!$0.isLetter && !$0.isNumber}).filter{$0.count>=3}.map(String.init))
}
var rows:[[String:Any]]=[]
for pair in pairs {
 let total=pair.subject+" "+pair.content
 let q=embedding(pair.query),full=embedding(total),body=embedding(pair.content)
 let qFixed=embedding(pair.query,forcedLanguage:pair.language)
 let fullScore=cosine(q,full),bodyScore=cosine(q,body)
 let chunkScore=chunks(pair.content).compactMap{cosine(q,embedding($0))}.max()
 let forcedBodyScore=cosine(qFixed,embedding(pair.content,forcedLanguage:pair.language))
 let folded=total.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
 let lexical=words(pair.query).filter{folded.contains($0)}.sorted()
 rows.append(["id":pair.id,"query":pair.query,"subject":pair.subject,"content":pair.content,"related":pair.related,"declared_language":pair.language,
 "query_language":q?.language as Any? ?? NSNull(),"total_language":full?.language as Any? ?? NSNull(),"content_language":body?.language as Any? ?? NSNull(),
 "query_model_revision":q?.revision as Any? ?? NSNull(),"total_cosine":json(fullScore),"content_cosine":json(bodyScore),"sentence_chunks_cosine":json(chunkScore),"forced_content_cosine":json(forcedBodyScore),"lexical_matches":lexical,
 "current_semantic_admitted":(fullScore ?? 0)>=0.55,"content_semantic_admitted":(bodyScore ?? 0)>=0.55,"forced_content_semantic_admitted":(forcedBodyScore ?? 0)>=0.55,"current_hybrid_admitted":!lexical.isEmpty || (fullScore ?? 0)>=0.55])
}
let output:[String:Any]=["threshold":0.55,"rows":rows,"limitations":["Synthetic corpus, not a quality benchmark", "Contradictory memories can be useful retrieval evidence; similarity does not establish truth or authorization", "No embedding/model downloads or network calls", "Forced language is diagnostic only, not implemented in AIM"]]
let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic)
print("Evaluated \(rows.count) pairs using available Apple embeddings.")
