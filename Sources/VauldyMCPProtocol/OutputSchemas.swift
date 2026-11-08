import MCP

private let textSchema: Value = .object(["type": .string("string")])
private let boolSchema: Value = .object(["type": .string("boolean")])
private let countSchema: Value = .object(["type": .string("integer"), "minimum": .int(0)])
private func array(_ item: Value) -> Value { .object(["type": .string("array"), "items": item]) }
private func object(_ properties: [String: Value], optional: Set<String> = []) -> Value {
    .object(["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
             "required": .array(properties.keys.filter { !optional.contains($0) }.sorted().map(Value.string))])
}
private let disclosureSchema = object([
    "processingLocation": textSchema, "hostCanReadResults": boolSchema, "pseudonymized": boolSchema,
    "anonymous": boolSchema, "warning": textSchema
])
private let coverageSchema = object([
    "scope": textSchema, "authorizedDocumentCount": countSchema, "searchableDocumentCount": countSchema,
    "completeSourceDocumentCount": countSchema, "pendingDocumentCount": countSchema, "failedDocumentCount": countSchema,
    "reviewDocumentCount": countSchema, "unknownCoverageDocumentCount": countSchema, "missingGrantedDocumentCount": countSchema
])
private let hitSchema = object([
    "document": textSchema, "title": textSchema, "page": countSchema, "excerpt": textSchema, "source": textSchema,
    "processingStatus": textSchema, "sourceCoverage": textSchema, "analysisStatus": textSchema
], optional: ["page"])

private let analysisCoverageSchema = object([
    "completed": countSchema, "needsReview": countSchema, "unavailable": countSchema, "failed": countSchema,
    "notAnalyzed": countSchema, "stale": countSchema, "scope": textSchema
])
let statusOutputSchema = object([
    "access": textSchema, "available": boolSchema, "grantedDocumentCount": countSchema,
    "searchableDocumentCount": countSchema, "coverage": coverageSchema, "warnings": array(textSchema), "processingComplete": boolSchema,
    "readOnly": boolSchema, "disclosure": disclosureSchema, "analysisCoverage": analysisCoverageSchema
])
let searchOutputSchema = object([
    "hits": array(hitSchema), "mode": textSchema, "limit": countSchema, "totalCount": countSchema,
    "truncated": boolSchema, "retrievalComplete": boolSchema, "processingComplete": boolSchema,
    "coverage": coverageSchema, "warnings": array(textSchema), "disclosure": disclosureSchema
])
let listOutputSchema = object([
    "mode": textSchema, "filter": textSchema, "snapshot": textSchema, "items": array(hitSchema),
    "totalCount": countSchema, "hasMore": boolSchema, "nextCursor": textSchema,
    "retrievalComplete": boolSchema, "processingComplete": boolSchema, "coverage": coverageSchema,
    "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["nextCursor"])

let contentOutputSchema = object([
    "document": textSchema, "title": textSchema,
    "segments": array(object(["page": countSchema, "part": countSchema, "text": textSchema, "source": textSchema], optional: ["page"])),
    "expectedPageCount": countSchema, "availablePages": array(countSchema), "sourceCoverage": textSchema,
    "nextCursor": textSchema, "containsEntireAvailableText": boolSchema,
    "analysisStatus": textSchema, "pageStatus": array(object(["page": countSchema, "method": textSchema, "needsReview": boolSchema])),
    "disclosure": disclosureSchema
], optional: ["nextCursor", "expectedPageCount"])

private let analysisFieldSchema = object([
    "role": textSchema, "value": textSchema, "page": countSchema, "quote": textSchema, "source": textSchema
])
let topicOverviewOutputSchema = object([
    "contractVersion": countSchema,
    "rows": array(object([
        "document": textSchema, "status": textSchema, "processingStatus": textSchema,
        "evidence": object(["page": countSchema, "quote": textSchema, "source": textSchema]),
        "issuer": analysisFieldSchema, "subject": analysisFieldSchema
    ], optional: ["evidence", "issuer", "subject"])),
    "candidateCount": countSchema, "nextCursor": textSchema, "retrievalComplete": boolSchema,
    "processingComplete": boolSchema, "coverage": coverageSchema,
    "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["nextCursor"])
private let fieldEvidenceSchema = object(["label": textSchema, "value": textSchema, "page": countSchema,
                                          "quote": textSchema, "source": textSchema])
let fieldExtractionOutputSchema = object([
    "contractVersion": countSchema, "scope": textSchema,
    "results": array(object([
        "document": textSchema, "field": textSchema, "status": textSchema,
        "evidence": array(fieldEvidenceSchema),
        "evidenceCount": countSchema, "evidenceOffset": countSchema, "evidenceComplete": boolSchema,
        "sourceCoverage": textSchema, "warnings": array(textSchema)
    ])),
    "nextCursor": textSchema, "retrievalComplete": boolSchema, "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["nextCursor"])
private let comparisonSideSchema = object([
    "document": textSchema, "sourceCoverage": textSchema, "identitySource": textSchema
], optional: ["identitySource"])
let contractComparisonOutputSchema = object([
    "contractVersion": countSchema, "scope": textSchema, "status": textSchema,
    "before": comparisonSideSchema, "after": comparisonSideSchema,
    "rows": array(object(["field": textSchema, "aspect": textSchema, "status": textSchema,
                          "before": fieldEvidenceSchema, "after": fieldEvidenceSchema,
                          "beforeEvidenceCount": countSchema, "afterEvidenceCount": countSchema,
                          "warnings": array(textSchema)], optional: ["before", "after"])),
    "warnings": array(textSchema), "disclosure": disclosureSchema
])
let metadataOutputSchema = object([
    "document": textSchema, "view": textSchema, "analysisStatus": textSchema, "engine": textSchema,
    "analyzedPages": array(countSchema), "logicalDocumentCount": countSchema,
    "documents": array(object(["pages": array(countSchema), "documentType": textSchema, "title": textSchema,
                                "overview": textSchema, "fields": array(analysisFieldSchema), "warnings": array(textSchema)], optional: ["overview"])),
    "hasMore": boolSchema, "nextCursor": textSchema, "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["engine", "nextCursor"])
private let passagesOutputSchema = object([
    "document": textSchema, "title": textSchema, "mode": textSchema,
    "segments": array(object(["page": countSchema, "part": countSchema, "text": textSchema, "source": textSchema], optional: ["page"])),
    "matchingPassageCount": countSchema, "nextCursor": textSchema, "retrievalComplete": boolSchema,
    "containsEntireAvailableText": boolSchema, "sourceCoverage": textSchema, "analysisStatus": textSchema,
    "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["nextCursor"])
let readOutputSchema: Value = .object(["type": .string("object"), "anyOf": .array([contentOutputSchema, metadataOutputSchema, passagesOutputSchema])])

let deadlineOverviewOutputSchema = object([
    "contractVersion": countSchema, "scope": textSchema,
    "rows": array(object([
        "document": textSchema, "sourceCoverage": textSchema,
        "entries": array(object([
            "role": textSchema, "status": textSchema, "date": textSchema, "evidence": array(fieldEvidenceSchema),
            "evidenceCount": countSchema, "warnings": array(textSchema)
        ], optional: ["date"])),
        "calculationStatus": textSchema,
        "calculation": object(["date": textSchema, "method": textSchema, "ruleSource": textSchema, "endDateSource": textSchema]),
        "warnings": array(textSchema)
    ], optional: ["calculation"])),
    "warnings": array(textSchema), "disclosure": disclosureSchema
])

let inventoryOutputSchema = object([
    "contractVersion": countSchema, "scope": textSchema, "identityScope": textSchema,
    "identityAlgorithm": textSchema, "contentHashScope": textSchema, "order": textSchema,
    "snapshot": textSchema,
    "items": array(object([
        "document": textSchema,
        "documentID": .object(["type": .string("string"), "pattern": .string("^doc_[0-9a-f]{64}$")]),
        "importedAt": .object(["type": .string("string"), "format": .string("date-time")]),
        "contentHash": .object(["type": .string("string"), "pattern": .string("^[0-9a-f]{64}$")]),
        "originalState": textSchema, "processingStatus": textSchema, "sourceCoverage": textSchema
    ], optional: ["importedAt", "contentHash"])),
    "totalCount": countSchema, "nextCursor": textSchema, "retrievalComplete": boolSchema,
    "coverage": coverageSchema, "warnings": array(textSchema), "disclosure": disclosureSchema
], optional: ["nextCursor"])
