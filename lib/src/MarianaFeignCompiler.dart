import 'dart:ffi';
import 'dart:io';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:built_collection/built_collection.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dio/dio.dart';
import 'package:mariana_feign/annotation/FeignClient.dart';
import 'package:mariana_feign/annotation/Method.dart' as methodAnnotation;
import 'package:mariana_feign/annotation/HttpClient.dart';
import 'package:source_gen/source_gen.dart';
import 'package:tuple/tuple.dart';

class Options {
  Options();
}

class FeignClientGenerator extends GeneratorForAnnotation<FeignClient> {
  static const String _baseUrlVar = 'baseUrl';
  static const String _baseUrlGetter = 'getBaseUrl()';
  static const _queryParamsVar = "queryParameters";
  static const _dataVar = "data";
  static const _localDataVar = "_data";
  static const _dioVar = "getDio(null)";
  static const _dioLeftVar = "getDio(";
  static const _dioRightVar = ")";
  static const _extraVar = 'extra';
  static const _localExtraVar = '_extra';
  static const _contentType = 'contentType';
  static const _resultVar = "_result";
  static const _cancelToken = "cancelToken";
  static const _onSendProgress = "onSendProgress";
  static const _onReceiveProgress = "onReceiveProgress";
  static const _path = 'path';
  var hasCustomOptions = false;

  final Options globalOptions;

  FeignClientGenerator(this.globalOptions);

  late FeignClient clientAnnotation;

  @override
  String generateForAnnotatedElement(Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! ClassElement) {
      final name = element.displayName;
      throw InvalidGenerationSourceError(
        'Generator cannot target `$name`.',
        todo: 'Remove the [FeithClient] annotation from `$name`.',
      );
    }
    return _implementClass(element, annotation);
  }

  String _implementClass(ClassElement element, ConstantReader? annotation) {
    final className = element.name;
    final enumString = (annotation?.peek('parser')?.revive().accessor);
    final parser = Parser.values.firstWhereOrNull((e) => e.toString() == enumString);
    clientAnnotation = FeignClient(
      baseUrl: (annotation?.peek(_baseUrlVar)?.stringValue ?? ''),
      parser: (parser ?? Parser.JsonSerializable),
    );
    final baseUrl = clientAnnotation.baseUrl;
    final classBuilder = Class((c) {
      c..name = '${className}Impl'
        ..implements.add(refer(_generateTypeParameterizedName(element)))
        ..types.addAll(element.typeParameters.map((e) => refer(e.name)))
        ..methods.addAll([_buildBaseUrlGetterMethod(baseUrl), _buildDioGetterMethod()])
        ..methods.addAll(_parseMethods(element));
      if (hasCustomOptions) {
        c.methods.add(_generateOptionsCastMethod());
      }
      c.methods.add(_generateTypeSetterMethod());
    });
    return DartFormatter().format('${classBuilder.accept(DartEmitter())}');
  }

  String _generateTypeParameterizedName(TypeParameterizedElement element) =>
      element.displayName +
          (element.typeParameters.isNotEmpty
              ? '<${element.typeParameters.join(',')}>'
              : '');

  Method _buildDioGetterMethod() => Method((m) {
    m..returns = refer("Dio")
      ..name = "getDio"
      ..requiredParameters = ListBuilder([Parameter((p){
        p..name = 'instanceName'
          ..type = refer('String?');
      })])
      ..body = const Code("return GetIt.I.get<Dio>(instanceName: instanceName);");
  });

  Method _buildBaseUrlGetterMethod(String? url) => Method((m) {
    m..returns = refer("String?")
      ..name = "getBaseUrl"
      ..body = Code("return ${url?.isNotEmpty == true ? "\"$url\"" : null};");
  });

  Iterable<Method> _parseMethods(ClassElement element) =>
      element.methods.where((MethodElement m) {
        final methodAnnot = _getMethodAnnotation(m);
        return methodAnnot != null &&
            m.isAbstract &&
            (m.returnType.isDartAsyncFuture || m.returnType.isDartAsyncStream);
      }).map((m) => _generateMethod(m)!);

  final _methodsAnnotations = const [
    methodAnnotation.GET,
    methodAnnotation.POST,
    methodAnnotation.DELETE,
    methodAnnotation.PUT,
    methodAnnotation.PATCH,
    methodAnnotation.HEAD,
    methodAnnotation.OPTIONS,
    methodAnnotation.Method
  ];

  TypeChecker _typeChecker(Type type) => TypeChecker.fromRuntime(type);

  ConstantReader? _getMethodAnnotation(MethodElement method) {
    for (final type in _methodsAnnotations) {
      final annot = _typeChecker(type)
          .firstAnnotationOf(method, throwOnUnresolved: false);
      if (annot != null) return ConstantReader(annot);
    }
    return null;
  }

  ConstantReader? _getHeadersAnnotation(MethodElement method) {
    final annot = _typeChecker(methodAnnotation.Headers)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annot != null) return ConstantReader(annot);
    return null;
  }

  ConstantReader? _getContentTypeAnnotation(MethodElement method) {
    var annotation = _typeChecker(methodAnnotation.FormUrlEncoded).firstAnnotationOf(method, throwOnUnresolved: false);
    if (annotation == null) {
      annotation = _typeChecker(methodAnnotation.JsonEncoded).firstAnnotationOf(method, throwOnUnresolved: false);
    }
    if (annotation != null) return ConstantReader(annotation);
    return null;
  }

  ConstantReader? _getResponseTypeAnnotation(MethodElement method) {
    final annotation = _typeChecker(DioResponseType)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annotation != null) return ConstantReader(annotation);
    return null;
  }

  Map<ParameterElement, ConstantReader> _getAnnotations(
      MethodElement m, Type type) {
    var annot = <ParameterElement, ConstantReader>{};
    for (final p in m.parameters) {
      final a = _typeChecker(type).firstAnnotationOf(p);
      if (a != null) {
        annot[p] = ConstantReader(a);
      }
    }
    return annot;
  }

  Tuple2<ParameterElement, ConstantReader>? _getAnnotation(
      MethodElement m, Type type) {
    for (final p in m.parameters) {
      final a = _typeChecker(type).firstAnnotationOf(p);
      if (a != null) {
        return Tuple2(p, ConstantReader(a));
      }
    }
    return null;
  }

  List<DartType>? _genericListOf(DartType type) {
    return type is ParameterizedType && type.typeArguments.isNotEmpty
        ? type.typeArguments
        : null;
  }

  DartType? _genericOf(DartType type) {
    return type is InterfaceType && type.typeArguments.isNotEmpty
        ? type.typeArguments.first
        : null;
  }

  DartType? _getResponseType(DartType type) {
    return _genericOf(type);
  }

  /// get types for `Map<String, List<User>>`, `A<B,C,D>`
  List<DartType>? _getResponseInnerTypes(DartType type) {
    final genericList = _genericListOf(type);
    return genericList;
  }

  DartType? _getResponseInnerType(DartType type) {
    final generic = _genericOf(type);
    if (generic == null ||
        _typeChecker(Map).isExactlyType(type) ||
        _typeChecker(BuiltMap).isExactlyType(type)) return type;

    if (generic.isDynamic) return null;

    if (_typeChecker(List).isExactlyType(type) ||
        _typeChecker(BuiltList).isExactlyType(type)) return generic;

    return _getResponseInnerType(generic);
  }

  Method? _generateMethod(MethodElement m) {
    final httpMehod = _getMethodAnnotation(m);
    if (httpMehod == null){
      return null;
    }

    return Method((mm) {
      mm..returns = refer(_displayString(m.type.returnType))
        ..name = m.displayName
        ..types.addAll(m.typeParameters.map((e) => refer(e.name)))
        ..modifier = m.returnType.isDartAsyncFuture
            ? MethodModifier.async
            : MethodModifier.asyncStar
        ..annotations.add(CodeExpression(Code('override')));

      mm.requiredParameters.addAll(m.parameters
          .where((it) => it.isRequiredPositional)
          .map((it) => Parameter((p) => p
        ..name = it.name
        ..named = it.isNamed)));

      mm.optionalParameters.addAll(m.parameters.where((i) => i.isOptional || i.isRequiredNamed).map(
              (it) => Parameter((p) => p
            ..required = (it.isNamed && it.type.nullabilitySuffix == NullabilitySuffix.none && !it.hasDefaultValue)
            ..name = it.name
            ..named = it.isNamed
            ..defaultTo = it.defaultValueCode == null
                ? null
                : Code(it.defaultValueCode!))));
      mm.body = _generateRequest(m, httpMehod);
    });
  }

  Expression _generatePath(MethodElement m, ConstantReader method) {
    final paths = _getAnnotations(m, methodAnnotation.Path);
    String? definePath = method.peek("path")?.stringValue;
    paths.forEach((k, v) {
      final value = v.peek("value")?.stringValue ?? k.displayName;
      definePath = definePath?.replaceFirst("{$value}", "\$${k.displayName}");
    });
    return literal(definePath);
  }

  String? _generateHttpClient(List<Code> blocks, MethodElement m) {
    final prepared = _getAnnotations(m, methodAnnotation.Client);
    if (prepared.length == 1) {
      return _dioLeftVar + prepared.keys.first.displayName + _dioRightVar;
    }
    return null;
  }

  Code _generateRequest(MethodElement m, ConstantReader httpMethod) {
    final returnAsyncWrapper = m.returnType.isDartAsyncFuture ? 'return' : 'yield';
    final path = _generatePath(m, httpMethod);
    final blocks = <Code>[];
    String clientName = _generateHttpClient(blocks, m) ?? _dioVar;
    
    _generatePreparedNotify(blocks, m);
    _generateExtra(m, blocks, _localExtraVar);

    _generateQueries(m, blocks, _queryParamsVar);
    Map<String, Expression> headers = _generateHeaders(m);
    _generateRequestBody(blocks, _localDataVar, m);

    final extraOptions = {
      "method": literal(httpMethod.peek("method")?.stringValue),
      "headers": literalMap(
          headers.map((k, v) => MapEntry(literalString(k, raw: true), v)),
          refer("String"),
          refer("dynamic")),
      _extraVar: refer(_localExtraVar),
    };

    final contentTypeInHeader = headers.entries
        .firstWhereOrNull((i) => "Content-Type".toLowerCase() == i.key.toLowerCase())
        ?.value;
    if (contentTypeInHeader != null) {
      extraOptions[_contentType] = contentTypeInHeader;
    }

    final contentType = _getContentTypeAnnotation(m);
    if (contentType != null) {
      extraOptions[_contentType] =
          literal(contentType.peek("mime")?.stringValue);
    }
    extraOptions[_baseUrlVar] = refer(_baseUrlGetter);

    final responseType = _getResponseTypeAnnotation(m);
    if (responseType != null) {
      final rsType = ResponseType.values.firstWhere((it) {
        return responseType
            .peek("responseType")
            ?.objectValue
            .toString()
            .contains(it.toString().split(".")[1]) ?? false;
      });

      extraOptions["responseType"] = refer(rsType.toString());
    }
    final namedArguments = <String, Expression>{};
    namedArguments[_queryParamsVar] = refer(_queryParamsVar);
    namedArguments[_path] = path;
    namedArguments[_dataVar] = refer(_localDataVar);

    final cancelToken = _getAnnotation(m, CancelRequest);
    if (cancelToken != null)
      namedArguments[_cancelToken] = refer(cancelToken.item1.displayName);

    final sendProgress = _getAnnotation(m, SendProgress);
    if (sendProgress != null)
      namedArguments[_onSendProgress] = refer(sendProgress.item1.displayName);

    final receiveProgress = _getAnnotation(m, ReceiveProgress);
    if (receiveProgress != null)
      namedArguments[_onReceiveProgress] =
          refer(receiveProgress.item1.displayName);

    final wrapperedReturnType = _getResponseType(m.returnType);

    final options = _parseOptions(clientName, m, namedArguments, blocks, extraOptions);

    if (wrapperedReturnType == null ||
        "void" == wrapperedReturnType.toString()) {
      blocks.add(
        refer("await $clientName.fetch")
            .call([options], {}, [refer("void")])
            .statement,
      );
      _generateFinishNotify(blocks, m);
      blocks.add(Code("$returnAsyncWrapper null;"));
      return Block.of(blocks);
    }

    final bool isWrappered =
    _typeChecker(HttpResponse).isExactlyType(wrapperedReturnType);
    final returnType = isWrappered
        ? _getResponseType(wrapperedReturnType)
        : wrapperedReturnType;
    if (returnType == null || "void" == returnType.toString()) {
      if (isWrappered) {
        blocks.add(
          refer("final $_resultVar = await $clientName.fetch")
              .call([options], {}, [refer("void")])
              .statement,
        );
        blocks.add(Code("""
      final httpResponse = HttpResponse(null, $_resultVar);
      $returnAsyncWrapper httpResponse;
      """));
      } else {
        blocks.add(
          refer("await $clientName.fetch")
              .call([options], {}, [refer("void")])
              .statement,
        );
        blocks.add(Code("$returnAsyncWrapper null;"));
      }
    } else {
      final innerReturnType = _getResponseInnerType(returnType);
      if (_typeChecker(List).isExactlyType(returnType) ||
          _typeChecker(BuiltList).isExactlyType(returnType)) {
        if (_isBasicType(innerReturnType)) {
          blocks.add(
            refer("await $clientName.fetch<List<dynamic>>")
                .call([options])
                .property("catchError")
                .call([
              refer('''
                        (e) {
                          ${_FinishToString(m)}
                          GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                        }
                      ''')
            ]).assignFinal(_resultVar)
                .statement,
          );
          blocks.add(Code(
              "final value = $_resultVar.data!.cast<${_displayString(innerReturnType)}>();"));
        } else {
          blocks.add(
            refer("await $clientName.fetch<List<dynamic>>")
                .call([options])
                .property("catchError")
                .call([
              refer('''
                        (e) {
                          ${_FinishToString(m)}
                          GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                        }
                      ''')
            ]).assignFinal(_resultVar)
                .statement,
          );
          switch (clientAnnotation.parser) {
            case Parser.MapSerializable:
              blocks.add(Code(
                  "var value = $_resultVar.data!.map((dynamic i) => ${_displayString(innerReturnType)}.fromMap(i as Map<String,dynamic>)).toList();"));
              break;
            case Parser.JsonSerializable:
              blocks.add(Code(
                  "var value = $_resultVar.data!.map((dynamic i) => ${_displayString(innerReturnType)}.fromJson(i as Map<String,dynamic>)).toList();"));
              break;
            case Parser.DartJsonMapper:
              blocks.add(Code(
                  "var value = $_resultVar.data!.map((dynamic i) => JsonMapper.fromMap<${_displayString(innerReturnType)}>(i as Map<String,dynamic>)!).toList();"));
              break;
            default:
              throw ArgumentError('No parser set. Use either MapSerializable, JsonSerializable or DartJsonMapper');
          }
        }
      } else if (_typeChecker(Map).isExactlyType(returnType) ||
          _typeChecker(BuiltMap).isExactlyType(returnType)) {
        final types = _getResponseInnerTypes(returnType)!;
        blocks.add(
          refer("await $clientName.fetch<Map<String,dynamic>>")
              .call([options])
              .property("catchError")
              .call([
            refer('''
                        (e) {
                          ${_FinishToString(m)}
                          GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                        }
                      ''')
          ]).assignFinal(_resultVar)
              .statement,
        );

        /// assume the first type is a basic type
        if (types.length > 1) {
          final secondType = types[1];
          if (_typeChecker(List).isExactlyType(secondType) ||
              _typeChecker(BuiltList).isExactlyType(secondType)) {
            final type = _getResponseType(secondType);
            switch (clientAnnotation.parser) {
              case Parser.MapSerializable:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => ${_displayString(type)}.fromMap(i as Map<String,dynamic>))
                    .toList()
                )
              );
            """));
                break;
              case Parser.JsonSerializable:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => ${_displayString(type)}.fromJson(i as Map<String,dynamic>))
                    .toList()
                )
              );
            """));
                break;
              case Parser.DartJsonMapper:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => JsonMapper.fromMap<${_displayString(type)}>(i as Map<String,dynamic>)!)
                    .toList()
                )
              );
            """));
                break;
              default:
                throw ArgumentError('No parser set. Use either MapSerializable, JsonSerializable or DartJsonMapper');
            }
          } else if (!_isBasicType(secondType)) {
            switch (clientAnnotation.parser) {
              case Parser.MapSerializable:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(k, ${_displayString(secondType)}.fromMap(v as Map<String, dynamic>))
              );
            """));
                break;
              case Parser.JsonSerializable:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(k, ${_displayString(secondType)}.fromJson(v as Map<String, dynamic>))
              );
            """));
                break;
              case Parser.DartJsonMapper:
                blocks.add(Code("""
            var value = $_resultVar.data!
              .map((k, dynamic v) =>
                MapEntry(k, JsonMapper.fromMap<${_displayString(secondType)}>(v as Map<String, dynamic>)!)
              );
            """));
                break;
              default:
                throw ArgumentError('No parser set. Use either MapSerializable, JsonSerializable or DartJsonMapper');
            }
          }
        } else {
          blocks.add(Code("final value = $_resultVar.data!;"));
        }
      } else {
        if (_isBasicType(returnType)) {
          blocks.add(
            refer("await $clientName.fetch<${_displayString(returnType)}>")
                .call([options])
                .property("catchError")
                .call([
              refer('''
                        (e) {
                          ${_FinishToString(m)}
                          GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                        }
                      ''')
            ]).assignFinal(_resultVar)
                .statement,
          );
          blocks.add(Code("final value = $_resultVar.data!;"));
        } else if (returnType.toString() == 'dynamic') {
          blocks.add(
            refer("await $clientName.fetch")
                .call([options])
                .property("catchError")
                .call([
              refer('''
                        (e) {
                          ${_FinishToString(m)}
                          GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                        }
                      ''')
            ]).assignFinal(_resultVar)
                .statement,
          );
          blocks.add(Code("final value = $_resultVar.data!;"));
        } else {
          blocks.add(
            refer("await $clientName.fetch<Map<String,dynamic>>")
                .call([options])
                .property("catchError")
                .call([
              refer('''
                            (e) {
                              ${_FinishToString(m)}
                              GetIt.I.get<Function>(instanceName: \"errorCallback\").call(e);
                            }
                          ''')
            ]).assignFinal(_resultVar)
                .statement,
          );
          switch (clientAnnotation.parser) {
            case Parser.MapSerializable:
              blocks.add(Code(
                  "final value = ${_displayString(returnType)}.fromMap($_resultVar.data!);"));
              break;
            case Parser.JsonSerializable:
              final genericArgumentFactories = isGenericArgumentFactories(returnType);

              // print('genericArgumentFactories:$genericArgumentFactories');
              var typeArgs = returnType is ParameterizedType
                  ? returnType.typeArguments
                  : [];
              var mapperVal;

              if (typeArgs.length > 0 && genericArgumentFactories) {
                mapperVal =
                "final value = ${_displayString(returnType)}.fromJson($_resultVar.data!,${_getInnerJsonSerializableMapperFn(returnType)});";
              } else {
                mapperVal =
                "final value = ${_displayString(returnType)}.fromJson($_resultVar.data!);";
              }
              blocks.add(Code(mapperVal));
              break;
            case Parser.DartJsonMapper:
              blocks.add(Code(
                  "final value = JsonMapper.fromMap<${_displayString(returnType)}>($_resultVar.data!)!;"));
              break;
            default:
              throw ArgumentError('No parser set. Use either MapSerializable, JsonSerializable or DartJsonMapper');
          }
        }
      }
      _generateFinishNotify(blocks, m);
      if (isWrappered) {
        blocks.add(Code("""
      final httpResponse = HttpResponse(value, $_resultVar);
      $returnAsyncWrapper httpResponse;
      """));
      } else {
        _generateDataNotify(blocks, m, "value");
        blocks.add(Code("$returnAsyncWrapper value;"));
      }
    }
    return Block.of(blocks);
  }

  bool isGenericArgumentFactories(DartType? dartType){
    final metaData = dartType?.element?.metadata;
    if (metaData == null || dartType == null) {
      return false;
    }
    final constDartObj = metaData.isNotEmpty ? metaData.first.computeConstantValue():null;
    var genericArgumentFactories = false;
    if (constDartObj != null && (!_typeChecker(List).isExactlyType(dartType) &&
        !_typeChecker(BuiltList).isExactlyType(dartType))){
      try{
        final annotation = ConstantReader(constDartObj);
        final obj =  (annotation.peek('genericArgumentFactories'));
        // ignore: invalid_null_aware_operator
        genericArgumentFactories = obj?.boolValue ?? false;
      } catch (e) { }
    }

    return genericArgumentFactories;
  }

  String _getInnerJsonSerializableMapperFn(DartType dartType) {

    var typeArgs = dartType is ParameterizedType ? dartType.typeArguments : [];
    if (typeArgs.length > 0 ) {
      if (_typeChecker(List).isExactlyType(dartType) ||
          _typeChecker(BuiltList).isExactlyType(dartType)) {
        var genericType = _getResponseType(dartType);
        var typeArgs = genericType is ParameterizedType ? genericType.typeArguments : [];
        var mapperVal;

        var genericTypeString = "${_displayString(genericType)}";

        if (typeArgs.length > 0 && isGenericArgumentFactories(genericType) && genericType != null) {
          mapperVal = """
    (json)=> (json as List<dynamic>)
            .map<${genericTypeString}>((i) => ${genericTypeString}.fromJson(
                  i as Map<String, dynamic>,${_getInnerJsonSerializableMapperFn(genericType)}
                ))
            .toList()
    """;
        } else {
          if (_isBasicType(genericType)){
            mapperVal = """
    (json)=>(json as List<dynamic>)
            .map<${genericTypeString}>((i) => 
                  i as ${genericTypeString}
                )
            .toList()
    """;
          }else
          {
            mapperVal = """
    (json)=>(json as List<dynamic>)
            .map<${genericTypeString}>((i) =>
            ${genericTypeString == 'dynamic' ? ' i as Map<String, dynamic>' : genericTypeString + '.fromJson(  i as Map<String, dynamic> )  '}
    )
            .toList()
    """;
          }
        }
        return mapperVal;
      } else {
        var mappedVal = '';
        for (DartType arg in typeArgs) {
          // print(arg);
          var typeArgs = arg is ParameterizedType
              ? arg.typeArguments
              : [];
          if (typeArgs.length > 0 )
            if (_typeChecker(List).isExactlyType(arg) ||
                _typeChecker(BuiltList).isExactlyType(arg)) {
              mappedVal += "${_getInnerJsonSerializableMapperFn(arg)}";
            }else{
              if (isGenericArgumentFactories(arg))
                mappedVal += "(json)=>${_displayString(arg)}.fromJson(json,${_getInnerJsonSerializableMapperFn(arg)}),";
              else
                mappedVal += "(json)=>${_displayString(arg)}.fromJson(json),";
            }
          else{
            mappedVal += "${_getInnerJsonSerializableMapperFn(arg)}";
          }
        }
        return mappedVal;
      }
    } else {
      if ( _displayString(dartType) == 'dynamic' || _isBasicType(dartType)){
        return "(json)=>json as ${_displayString(dartType)},";

      }else
        return "(json)=>${_displayString(dartType)}.fromJson(json),";
    }
  }

  Expression _parseOptions(
      String clientName,
      MethodElement m,
      Map<String, Expression> namedArguments,
      List<Code> blocks,
      Map<String, Expression> extraOptions) {
    final annoOptions = _getAnnotation(m, DioOptions);
    if (annoOptions == null) {
      final args = Map<String, Expression>.from(extraOptions)..addAll(namedArguments);
      final path = args.remove(_path)!;
      final dataVar = args.remove(_dataVar)!;
      final queryParams = args.remove(_queryParamsVar)!;
      final baseUrl = args.remove(_baseUrlVar)!;
      final cancelToken = args.remove(_cancelToken);
      final sendProgress = args.remove(_onSendProgress);

      final type = refer(_displayString(_getResponseType(m.returnType)));

      final composeArguments = <String,Expression>{_queryParamsVar: queryParams, _dataVar: dataVar};
      if (cancelToken != null) {
        composeArguments[_cancelToken] = cancelToken;
      }
      if (sendProgress != null){
        composeArguments[_onSendProgress] = sendProgress;
      }

      return refer('_setStreamType').call([
        refer("Options")
            .newInstance([], args)
            .property('compose')
            .call(
          [refer(clientName).property('options'), path], composeArguments,
        )
            .property('copyWith')
            .call([], {
          _baseUrlVar: baseUrl.ifNullThen(
              refer(clientName).property('options').property('baseUrl'))
        })
      ], {}, [
        type
      ]);
    } else {
      hasCustomOptions = true;
      blocks.add(refer("newRequestOptions")
          .call([refer(annoOptions.item1.displayName)])
          .assignFinal("newOptions")
          .statement);
      final newOptions = refer("newOptions");
      blocks.add(newOptions
          .property(_extraVar)
          .property('addAll')
          .call([extraOptions.remove(_extraVar)!]).statement);
      blocks.add(newOptions
          .property('headers')
          .property('addAll')
          .call([extraOptions.remove('headers')!]).statement);
      return newOptions.property('copyWith').call([], Map.from(extraOptions)
        ..[_queryParamsVar] = namedArguments[_queryParamsVar]!
        ..[_path] = namedArguments[_path]!).cascade('data').assign(namedArguments[_dataVar]!);
    }
  }

  Method _generateOptionsCastMethod() {
    return Method((m) {
      m
        ..name = "newRequestOptions"
        ..returns = refer("RequestOptions")

        ..requiredParameters.add(Parameter((p) {
          p.name = "options";
          p.type = refer("Options?").type;
        }))

        ..body = Code('''
         if (options is RequestOptions) {
            return options as RequestOptions;
          }
          if (options == null) {
            return RequestOptions(path: '');
          }
          return RequestOptions(
            method: options.method,
            sendTimeout: options.sendTimeout,
            receiveTimeout: options.receiveTimeout,
            extra: options.extra,
            headers: options.headers,
            responseType: options.responseType,
            contentType: options.contentType.toString(),
            validateStatus: options.validateStatus,
            receiveDataWhenStatusError: options.receiveDataWhenStatusError,
            followRedirects: options.followRedirects,
            maxRedirects: options.maxRedirects,
            requestEncoder: options.requestEncoder,
            responseDecoder: options.responseDecoder,
            path: '',
          );
        ''');
    });
  }

  Method _generateTypeSetterMethod() {
    return Method((m){
      final t = refer('T');
      final optionsParam = Parameter((p){
        p..name = 'requestOptions'
          ..type = refer('RequestOptions');
      });
      m..name = '_setStreamType'
        ..types = ListBuilder([t])
        ..returns = refer('RequestOptions')
        ..requiredParameters = ListBuilder([optionsParam])
        ..body = Code('''if (T != dynamic &&
        !(requestOptions.responseType == ResponseType.bytes ||
            requestOptions.responseType == ResponseType.stream)) {
      if (T == String) {
        requestOptions.responseType = ResponseType.plain;
      } else {
        requestOptions.responseType = ResponseType.json;
      }
    }
    return requestOptions;''');
    });
  }

  bool _isBasicType(DartType? returnType) {
    if (returnType == null) {
      return false;
    }
    return _typeChecker(String).isExactlyType(returnType) ||
        _typeChecker(bool).isExactlyType(returnType) ||
        _typeChecker(int).isExactlyType(returnType) ||
        _typeChecker(double).isExactlyType(returnType) ||
        _typeChecker(num).isExactlyType(returnType) ||
        _typeChecker(Double).isExactlyType(returnType) ||
        _typeChecker(Float).isExactlyType(returnType);
  }

  bool _isBasicInnerType(DartType returnType) {
    var innnerType = _genericOf(returnType);
    return _isBasicType(innnerType);
  }

  void _generateQueries(
      MethodElement m, List<Code> blocks, String _queryParamsVar) {
    final queries = _getAnnotations(m, methodAnnotation.Query);
    final queryParameters = queries.map((p, ConstantReader r) {
      final key = r.peek("value")?.stringValue ?? p.displayName;
      final value = (_isBasicType(p.type) ||
          p.type.isDartCoreList ||
          p.type.isDartCoreMap)
          ? refer(p.displayName)
          : clientAnnotation.parser == Parser.DartJsonMapper
          ? refer(p.displayName)
          : clientAnnotation.parser == Parser.JsonSerializable
          ? p.type.nullabilitySuffix == NullabilitySuffix.question ? refer(p.displayName).nullSafeProperty('toJson').call([]) : refer(p.displayName).property('toJson').call([])
          : p.type.nullabilitySuffix == NullabilitySuffix.question ? refer(p.displayName).nullSafeProperty('toMap').call([]) : refer(p.displayName).property('toMap').call([]);
      return MapEntry(literalString(key, raw: true), value);
    });

    final queryMap = _getAnnotations(m, methodAnnotation.Queries);
    blocks.add(literalMap(queryParameters, refer("String"), refer("dynamic"))
        .assignFinal(_queryParamsVar)
        .statement);
    for (final p in queryMap.keys) {
      final type = p.type;
      final displayName = p.displayName;
      final value =
      (_isBasicType(type) || type.isDartCoreList || type.isDartCoreMap)
          ? refer(displayName)
          : clientAnnotation.parser == Parser.DartJsonMapper
          ? refer(displayName)
          : clientAnnotation.parser == Parser.JsonSerializable
          ? type.nullabilitySuffix == NullabilitySuffix.question ? refer(displayName).nullSafeProperty('toJson').call([]) : refer(displayName).property('toJson').call([])
          : type.nullabilitySuffix == NullabilitySuffix.question ? refer(displayName).nullSafeProperty('toMap').call([]) : refer(displayName).property('toMap').call([]);


      final emitter = DartEmitter();
      final buffer = StringBuffer();
      value.accept(emitter, buffer);
      if (type.nullabilitySuffix == NullabilitySuffix.question) {
        refer('?? <String,dynamic>{}').accept(emitter, buffer);
      }
      final expression = refer(buffer.toString());

      blocks.add(refer('$_queryParamsVar.addAll').call([expression]).statement);
    }

    if (m.parameters
        .where((p) => (p.type.nullabilitySuffix == NullabilitySuffix.question))
        .isNotEmpty) {
      blocks.add(Code("$_queryParamsVar.removeWhere((k, v) => v == null);"));
    }
  }

  void _generateRequestBody(List<Code> blocks, String _dataVar, MethodElement m) {
    final _bodyName = _getAnnotation(m, methodAnnotation.Body)?.item1;
    if (_bodyName != null) {
      final bodyTypeElement = _bodyName.type.element;
      if (TypeChecker.fromRuntime(Map).isAssignableFromType(_bodyName.type)) {
        blocks.add(literalMap({}, refer("String"), refer("dynamic"))
            .assignFinal(_dataVar)
            .statement);

        blocks.add(refer("$_dataVar.addAll").call([
          refer("${_bodyName.displayName}${m.type.nullabilitySuffix == NullabilitySuffix.question ? ' ?? <String,dynamic>{}' :''}")
        ]).statement);
      } else if (bodyTypeElement != null && ((_typeChecker(List).isExactly(bodyTypeElement) ||
          _typeChecker(BuiltList).isExactly(bodyTypeElement)) &&
          !_isBasicInnerType(_bodyName.type))) {
        blocks.add(refer('''
            ${_bodyName.displayName}.map((e) => e.toJson()).toList()
            ''').assignFinal(_dataVar).statement);
      } else if (bodyTypeElement != null && _typeChecker(File).isExactly(bodyTypeElement)) {
        blocks.add(refer("Stream")
            .property("fromIterable")
            .call([
          refer("${_bodyName.displayName}.readAsBytesSync().map((i)=>[i])")
        ])
            .assignFinal(_dataVar)
            .statement);
      } else if (_bodyName.type.element is ClassElement) {
        final ele = _bodyName.type.element as ClassElement;
        if (clientAnnotation.parser == Parser.MapSerializable) {
          final toMap = ele.lookUpMethod('toMap', ele.library);
          if (toMap == null) {
            log.warning(
                "${_displayString(_bodyName.type)} must provide a `toMap()` method which return a Map.\n"
                    "It is programmer's responsibility to make sure the ${_bodyName.type} is properly serialized");
            blocks.add(
                refer(_bodyName.displayName).assignFinal(_dataVar).statement);
          } else {
            blocks.add(literalMap({}, refer("String"), refer("dynamic"))
                .assignFinal(_dataVar)
                .statement);
            blocks.add(refer("$_dataVar.addAll").call([
              refer("${_bodyName.displayName}?.toMap() ?? <String,dynamic>{}")
            ]).statement);
          }
        } else {
          final toJson = ele.lookUpMethod('toJson', ele.library);
          if (toJson == null) {
            log.warning(
                "${_displayString(_bodyName.type)} must provide a `toJson()` method which return a Map.\n"
                    "It is programmer's responsibility to make sure the ${_displayString(_bodyName.type)} is properly serialized");
            blocks.add(
                refer(_bodyName.displayName).assignFinal(_dataVar).statement);
          } else {
            blocks.add(literalMap({}, refer("String"), refer("dynamic"))
                .assignFinal(_dataVar)
                .statement);
            if (_bodyName.type.nullabilitySuffix != NullabilitySuffix.question) {
              blocks.add(refer("$_dataVar.addAll").call([
                refer("${_bodyName.displayName}.toJson()")
              ]).statement);
            } else {
              blocks.add(refer("$_dataVar.addAll").call([
                refer("${_bodyName.displayName}?.toJson() ?? <String,dynamic>{}")
              ]).statement);
            }
          }
        }
      } else {
        /// @Body annotations with no type are assinged as is
        blocks
            .add(refer(_bodyName.displayName).assignFinal(_dataVar).statement);
      }

      return;
    }

    var anyNullable = false;
    final fields = _getAnnotations(m, methodAnnotation.Field).map((p, r) {
      anyNullable |= p.type.nullabilitySuffix == NullabilitySuffix.question;
      final fieldName = r.peek("value")?.stringValue ?? p.displayName;
      final isFileField = _typeChecker(File).isAssignableFromType(p.type);
      if (isFileField) {
        log.severe(
            'File is not support by @Field(). Please use @Part() instead.');
      }
      return MapEntry(literal(fieldName), refer(p.displayName));
    });

    if (fields.isNotEmpty) {
      blocks.add(literalMap(fields).assignFinal(_dataVar).statement);
      if (anyNullable) {
        blocks.add(Code("$_dataVar.removeWhere((k, v) => v == null);"));
      }
      return;
    }

    final parts = _getAnnotations(m, methodAnnotation.Part);
    if (parts.isNotEmpty) {
      blocks.add(refer('FormData').newInstance([]).assignFinal(_dataVar).statement);
      parts.forEach((p, r) {
        final fieldName = r.peek("name")?.stringValue ?? p.displayName;
        final isFileField = _typeChecker(File).isAssignableFromType(p.type);
        final contentType = r.peek('contentType')?.stringValue;
        if (p.type.isDartCoreMap) {
          blocks.add(refer(p.displayName).property("forEach").call([
            refer(''' 
                  (key, value) {
                    $_dataVar.fields.add(MapEntry(key, value));
                  }
                  ''')
          ]).statement);
        } else if (isFileField) {
          final fileName = r.peek("fileName")?.stringValue != null
              ? literalString(r.peek("fileName")!.stringValue)
              : refer(p.displayName)
              .property('path.split(Platform.pathSeparator).last');

          final uploadFileInfo = refer('$MultipartFile.fromFileSync').call([
            refer(p.displayName).property('path')
          ], {
            'filename': fileName,
            if (contentType != null)
              'contentType':
              refer("MediaType", 'package:http_parser/http_parser.dart')
                  .property('parse')
                  .call([literal(contentType)])
          });

          final optinalFile = m.parameters
              .firstWhereOrNull((pp) => pp.displayName == p.displayName)
              ?.isOptional ??
              false;

          final returnCode =
              refer(_dataVar).property('files').property("add").call([
                refer("MapEntry").newInstance([literal(fieldName), uploadFileInfo])
              ]).statement;
          if (optinalFile) {
            final condication =
                refer(p.displayName).notEqualTo(literalNull).code;
            blocks.addAll(
                [Code("if("), condication, Code(") {"), returnCode, Code("}")]);
          } else {
            blocks.add(returnCode);
          }
        } else if (_displayString(p.type) == "List<int>") {
          final fileName = r.peek("fileName")?.stringValue;
          final conType = contentType == null
              ? ""
              : 'contentType: MediaType.parse(${literal(contentType)}),';
          blocks.add(refer(_dataVar).property('files').property("add").call([
            refer(''' 
                  MapEntry(
                '${fieldName}',
                MultipartFile.fromBytes(${p.displayName},
                filename:${literal(fileName ?? null)},
                    ${conType}
                    ))
                  ''')
          ]).statement);
        } else if (_typeChecker(List).isExactlyType(p.type) ||
            _typeChecker(BuiltList).isExactlyType(p.type)) {
          var innerType = _genericOf(p.type);

          if (_displayString(innerType) == "List<int>") {
            final conType = contentType == null
                ? ""
                : 'contentType: MediaType.parse(${literal(contentType)}),';
            blocks
                .add(refer(_dataVar).property('files').property("addAll").call([
              refer(''' 
                  ${p.displayName}.map((i) => MapEntry(
                '${fieldName}',
                MultipartFile.fromBytes(i,
                    ${conType}
                    )))
                  ''')
            ]).statement);
          } else if (_isBasicType(innerType) || ((innerType != null) &&
              (_typeChecker(Map).isExactlyType(innerType) ||
                  _typeChecker(BuiltMap).isExactlyType(innerType) ||
                  _typeChecker(List).isExactlyType(innerType) ||
                  _typeChecker(BuiltList).isExactlyType(innerType)))) {
            var value = _isBasicType(innerType) ? 'i' : 'jsonEncode(i)';
            var nullableInfix = (p.type.nullabilitySuffix == NullabilitySuffix.question) ? '?' : '';
            blocks.add(refer('''
            ${p.displayName}$nullableInfix.forEach((i){
              ${_dataVar}.fields.add(MapEntry(${literal(fieldName)},${value}));
            })
            ''').statement);
          } else if (innerType != null && _typeChecker(File).isExactlyType(innerType)) {
            final conType = contentType == null
                ? ""
                : 'contentType: MediaType.parse(${literal(contentType)}),';
            blocks
                .add(refer(_dataVar).property('files').property("addAll").call([
              refer(''' 
                  ${p.displayName}.map((i) => MapEntry(
                '${fieldName}',
                MultipartFile.fromFileSync(i.path,
                    filename: i.path.split(Platform.pathSeparator).last,
                    ${conType}
                    )))
                  ''')
            ]).statement);
          } else if (innerType != null && _typeChecker(MultipartFile).isExactlyType(innerType)) {
            blocks
                .add(refer(_dataVar).property('files').property("addAll").call([
              refer(''' 
                  ${p.displayName}?.map((i) => MapEntry(
                '${fieldName}',
                i))
                  ''')
            ]).statement);
          } else if (innerType?.element is ClassElement) {
            final ele = innerType!.element as ClassElement;
            final toJson = ele.lookUpMethod('toJson', ele.library);
            if (toJson == null) {
              throw Exception("toJson() method have to add to ${p.type}");
            } else {
              blocks
                  .add(refer(_dataVar).property('fields').property("add").call([
                refer("MapEntry").newInstance(
                    [literal(fieldName), refer("jsonEncode(${p.displayName})")])
              ]).statement);
            }
          } else {
            throw Exception("Unknown error!");
          }
        } else if (_isBasicType(p.type)) {
          if (p.type.nullabilitySuffix == NullabilitySuffix.question) {
            blocks.add(Code("if (${p.displayName} != null) {"));
          }
          blocks.add(refer(_dataVar).property('fields').property("add").call([
            refer("MapEntry").newInstance([
              literal(fieldName),
              if (_typeChecker(String).isExactlyType(p.type))
                refer(p.displayName)
              else
                refer(p.displayName).property('toString').call([])
            ])
          ]).statement);
          if (p.type.nullabilitySuffix == NullabilitySuffix.question) {
            blocks.add(Code("}"));
          }
        } else if (p.type.element is ClassElement) {
          final ele = p.type.element as ClassElement;
          final toJson = ele.lookUpMethod('toJson', ele.library);
          if (toJson == null) {
            throw Exception("toJson() method have to add to ${p.type}");
          } else {
            blocks.add(refer(_dataVar).property('fields').property("add").call([
              refer("MapEntry").newInstance([
                literal(fieldName),
                refer("jsonEncode(${p.displayName}${p.type.nullabilitySuffix == NullabilitySuffix.question ? ' ?? <String,dynamic>{}' : ''})")
              ])
            ]).statement);
          }
        } else {
          blocks.add(refer(_dataVar).property('fields').property("add").call([
            refer("MapEntry")
                .newInstance([literal(fieldName), refer(p.displayName)])
          ]).statement);
        }
      });
      return;
    }

    /// There is no body
    blocks.add(literalMap({}, refer("String"), refer("dynamic"))
        .assignFinal(_dataVar)
        .statement);
  }

  Map<String, Expression> _generateHeaders(MethodElement m) {
    final anno = _getHeadersAnnotation(m);
    final headersMap = anno?.peek("value")?.mapValue ?? {};
    final headers = headersMap.map((k, v) {
      return MapEntry(k?.toStringValue() ?? 'null', literal(v?.toStringValue()));
    });

    final annosInParam = _getAnnotations(m, methodAnnotation.Header);
    final headersInParams = annosInParam.map((k, v) {
      final value = v.peek("value")?.stringValue ?? k.displayName;
      return MapEntry(value, refer(k.displayName));
    });
    headers.addAll(headersInParams);
    return headers;
  }

  void _generatePreparedNotify(List<Code> blocks, MethodElement m) {
    final prepared = _getAnnotations(m, methodAnnotation.Cancel);
    String? callbackName = null;
    switch (prepared.length) {
      case 0: {
        blocks.add(const Code('GetIt.I.get<Function>(instanceName: \"preparedCallback\").call();'));
      }
      break;
      case 1: {
        blocks.add(Code('''
          if (${prepared.keys.first.displayName} == null) {
            GetIt.I.get<Function>(instanceName: \"preparedCallback\").call();
          }
        '''));
      }
      break;
    }
  }

  void _generateDataNotify(List<Code> blocks, MethodElement m, String result) {
    final prepared = _getAnnotations(m, methodAnnotation.Callback);
    if (prepared.length == 1) {
      blocks.add(Code("GetIt.I.get<Function>(instanceName: \"dataCallback\").call(${prepared.keys.first.displayName}, $result);"));
    }
  }

  void _generateFinishNotify(List<Code> blocks, MethodElement m) {
    final prepared = _getAnnotations(m, methodAnnotation.Cancel);
    if (prepared.length == 1) {
      var parameter = prepared.keys.first.displayName;
      blocks.add(Code('''
        if ($parameter == null) {
          GetIt.I.get<Function>(instanceName: \"finishCallback\").call();
        } else {
          $parameter.call();
        }
      '''));
    } else {
      blocks.add(const Code("GetIt.I.get<Function>(instanceName: \"finishCallback\").call();"));
    }
  }

  String _FinishToString(MethodElement m) {
    final prepared = _getAnnotations(m, methodAnnotation.Cancel);
    if (prepared.length == 1) {
      var parameter = prepared.keys.first.displayName;
      return '''
        if ($parameter == null) {
          GetIt.I.get<Function>(instanceName: \"finishCallback\").call();
        } else {
          $parameter.call();
        }
      ''';
    } else {
      return "GetIt.I.get<Function>(instanceName: \"finishCallback\").call();";
    }
  }

  void _generateExtra(
      MethodElement m, List<Code> blocks, String localExtraVar) {
    final extra = _typeChecker(Extra)
        .firstAnnotationOf(m, throwOnUnresolved: false);

    if (extra != null) {
      final c = ConstantReader(extra);
      blocks.add(literalMap(
        c.peek('data')?.mapValue.map((k, v) {
          return MapEntry(
            k?.toStringValue() ??
                (throw InvalidGenerationSourceError(
                  'Invalid key for extra Map, only `String` keys are supported',
                  element: m,
                  todo: 'Make sure all keys are of string type',
                )),
            v?.toBoolValue() ??
                v?.toDoubleValue() ??
                v?.toIntValue() ??
                v?.toStringValue() ??
                v?.toListValue() ??
                v?.toMapValue() ??
                v?.toSetValue() ??
                v?.toSymbolValue() ??
                (v?.toTypeValue() ??
                    (v != null ? Code(revivedLiteral(v)) : Code('null'))),
          );
        }) ??
            {},
        refer('String'),
        refer('dynamic'),
      ).assignConst(localExtraVar).statement);
    } else {
      blocks.add(literalMap(
        {},
        refer('String'),
        refer('dynamic'),
      ).assignConst(localExtraVar).statement);
    }
  }
}

Builder generatorFactoryBuilder(BuilderOptions options) => SharedPartBuilder([FeignClientGenerator(Options())], "feign");

String revivedLiteral(
    Object object, {
      DartEmitter? dartEmitter,
    }) {
  dartEmitter ??= DartEmitter();

  ArgumentError.checkNotNull(object, 'object');

  Revivable? revived;
  if (object is Revivable) {
    revived = object;
  }
  if (object is DartObject) {
    revived = ConstantReader(object).revive();
  }
  if (object is ConstantReader) {
    revived = object.revive();
  }
  if (revived == null) {
    throw ArgumentError.value(object, 'object',
        'Only `Revivable`, `DartObject`, `ConstantReader` are supported values');
  }

  String instantiation = '';
  final location = revived.source.toString().split('#');

  if (location.length > 1) {
    instantiation = location[1] +
        (revived.accessor.isNotEmpty ? '.${revived.accessor}' : '');
  } else {
    return revived.accessor;
  }

  final args = StringBuffer();
  final kwargs = StringBuffer();
  Spec objectToSpec(DartObject? object) {
    if (object == null) return literalNull;
    final constant = ConstantReader(object);
    if (constant.isNull) {
      return literalNull;
    }

    if (constant.isBool) {
      return literal(constant.boolValue);
    }

    if (constant.isDouble) {
      return literal(constant.doubleValue);
    }

    if (constant.isInt) {
      return literal(constant.intValue);
    }

    if (constant.isString) {
      return literal(constant.stringValue);
    }

    if (constant.isList) {
      return literalList(constant.listValue.map(objectToSpec));
      // return literal(constant.listValue);
    }

    if (constant.isMap) {
      return literalMap(Map.fromIterables(
          constant.mapValue.keys.map(objectToSpec),
          constant.mapValue.values.map(objectToSpec)));
      // return literal(constant.mapValue);
    }

    if (constant.isSymbol) {
      return Code('Symbol(${constant.symbolValue.toString()})');
      // return literal(constant.symbolValue);
    }

    if (constant.isNull) {
      return literalNull;
    }

    if (constant.isType) {
      return refer(_displayString(constant.typeValue));
    }

    if (constant.isLiteral) {
      return literal(constant.literalValue);
    }

    final revived = revivedLiteral(constant.revive(), dartEmitter: dartEmitter)
        .replaceFirst('const ', '');
    return Code(revived);
  }

  for (var arg in revived.positionalArguments) {
    final literalValue = objectToSpec(arg);

    args.write('${literalValue.accept(dartEmitter)},');
  }

  for (var arg in revived.namedArguments.keys) {
    final literalValue = objectToSpec(revived.namedArguments[arg]!);

    kwargs.write('$arg:${literalValue.accept(dartEmitter)},');
  }

  return '$instantiation($args $kwargs)';
}

extension DartTypeStreamAnnotation on DartType {
  bool get isDartAsyncStream {
    final element = this.element == null ? null : this.element as ClassElement;
    if (element == null) {
      return false;
    }
    return element.name == "Stream" && element.library.isDartAsync;
  }
}

String _displayString(dynamic e) {
  try {
    return e.getDisplayString(withNullability: false);
  } catch (error) {
    if (error is TypeError) {
      return e.getDisplayString();
    } else {
      rethrow;
    }
  }
}

extension IterableExtension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (T element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}